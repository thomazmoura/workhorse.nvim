local M = {}

local client = require("workhorse.api.client")
local config = require("workhorse.config")
local builds_api = require("workhorse.api.builds")

local strip_nulls = builds_api.strip_nulls
local url_encode = builds_api.url_encode

-- Repositories come from every project of the organization, so paths use the repository's
-- own project (by id: project names may need escaping) instead of config.project
local function repo_path(repo, rest)
  return "/" .. repo.project.id .. "/_apis/git/repositories/" .. repo.id .. "/" .. rest
end

local function pr_path(repo, id, rest)
  return repo_path(repo, "pullRequests/" .. id .. (rest or ""))
end

local function display_name(identity)
  return type(identity) == "table" and identity.displayName or nil
end

local function commit_id(commit)
  return type(commit) == "table" and commit.commitId or nil
end

-- Web page of a repository (repositories listed by the API carry it as webUrl)
function M.repo_url(repo)
  if repo.web_url then
    return repo.web_url
  end
  local server = (config.get().server_url or ""):gsub("/$", "")
  return server .. "/" .. url_encode(repo.project.name) .. "/_git/" .. url_encode(repo.name)
end

function M.pr_url(repo, id)
  return M.repo_url(repo) .. "/pullrequest/" .. id
end

function M.commit_url(repo, sha)
  return M.repo_url(repo) .. "/commit/" .. sha
end

local function map_reviewer(r)
  strip_nulls(r)
  return {
    id = r.id,
    name = r.displayName or r.uniqueName or "?",
    vote = r.vote or 0,
    required = r.isRequired == true,
    declined = r.hasDeclined == true,
    -- Groups and teams added as reviewers (their vote is the one of the member who voted)
    group = r.isContainer == true,
  }
end

local function map_pr(repo, p)
  strip_nulls(p)
  local reviewers = {}
  for _, r in ipairs(type(p.reviewers) == "table" and p.reviewers or {}) do
    table.insert(reviewers, map_reviewer(r))
  end
  local options = type(p.completionOptions) == "table" and strip_nulls(p.completionOptions) or {}
  return {
    id = p.pullRequestId,
    title = p.title or "",
    description = p.description or "",
    status = p.status,
    is_draft = p.isDraft == true,
    created_by = display_name(p.createdBy),
    creation_date = p.creationDate,
    closed_date = p.closedDate,
    source_ref = p.sourceRefName,
    target_ref = p.targetRefName,
    merge_status = p.mergeStatus,
    auto_complete_set_by = display_name(p.autoCompleteSetBy),
    reviewers = reviewers,
    last_merge_source_commit = commit_id(p.lastMergeSourceCommit),
    completion_options = {
      merge_strategy = options.mergeStrategy,
      delete_source_branch = options.deleteSourceBranch,
    },
    url = M.pr_url(repo, p.pullRequestId),
  }
end

-- Git repositories of every project the PAT can see: callback({ { id, name, project = { id,
-- name }, default_branch, web_url } }) sorted by project then name, disabled ones left out
function M.list_repositories(callback)
  client.get("/_apis/git/repositories?api-version=7.1", {
    on_success = function(data)
      local repos = {}
      for _, r in ipairs(data and data.value or {}) do
        strip_nulls(r)
        if not r.isDisabled and type(r.project) == "table" then
          table.insert(repos, {
            id = r.id,
            name = r.name,
            project = { id = r.project.id, name = r.project.name },
            default_branch = r.defaultBranch,
            web_url = r.webUrl,
          })
        end
      end
      table.sort(repos, function(a, b)
        local ka, kb = (a.project.name .. "/" .. a.name):lower(), (b.project.name .. "/" .. b.name):lower()
        return ka < kb
      end)
      callback(repos)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- One page of the pull requests of a repository (all statuses, newest first)
function M.list(repo, skip, top, callback)
  client.get(repo_path(repo, "pullrequests?searchCriteria.status=all&$top=" .. top .. "&$skip=" .. skip
    .. "&api-version=7.1"), {
    on_success = function(data)
      local prs = {}
      for _, p in ipairs(data and data.value or {}) do
        table.insert(prs, map_pr(repo, p))
      end
      callback(prs)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- A single pull request (the list truncates descriptions)
function M.get(repo, id, callback)
  client.get(pr_path(repo, id, "?api-version=7.1"), {
    on_success = function(data)
      callback(data and map_pr(repo, data))
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Comment threads with their text comments: callback({ { id, status, file_path, right_line,
-- left_line, comments = { { author, date, content } } } }). System messages (votes, pushes)
-- and deleted comments are left out, as are threads left empty
function M.threads(repo, id, callback)
  client.get(pr_path(repo, id, "/threads?api-version=7.1"), {
    on_success = function(data)
      local threads = {}
      for _, t in ipairs(data and data.value or {}) do
        strip_nulls(t)
        local comments = {}
        for _, c in ipairs(type(t.comments) == "table" and t.comments or {}) do
          strip_nulls(c)
          if c.commentType ~= "system" and not c.isDeleted and type(c.content) == "string" then
            table.insert(comments, { author = display_name(c.author) or "?", date = c.publishedDate, content = c.content })
          end
        end
        if not t.isDeleted and #comments > 0 then
          local context = type(t.threadContext) == "table" and strip_nulls(t.threadContext) or {}
          local right = type(context.rightFileStart) == "table" and context.rightFileStart.line or nil
          local left = type(context.leftFileStart) == "table" and context.leftFileStart.line or nil
          table.insert(threads, {
            id = t.id,
            status = t.status,
            file_path = context.filePath,
            right_line = right,
            left_line = left,
            date = t.publishedDate,
            comments = comments,
          })
        end
      end
      callback(threads)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Pushes (iterations) of a pull request with the commits each one brought, oldest first
function M.iterations(repo, id, callback)
  client.get(pr_path(repo, id, "/iterations?includeCommits=true&api-version=7.1"), {
    on_success = function(data)
      local iterations = {}
      for _, it in ipairs(data and data.value or {}) do
        strip_nulls(it)
        local commits = {}
        for _, c in ipairs(type(it.commits) == "table" and it.commits or {}) do
          local author = type(c.author) == "table" and c.author or {}
          table.insert(commits, { id = c.commitId, author = author.name, date = author.date, message = c.comment or "" })
        end
        table.insert(iterations, {
          id = it.id,
          description = it.description,
          reason = it.reason,
          author = display_name(it.author),
          created = it.createdDate,
          source_commit = commit_id(it.sourceRefCommit),
          target_commit = commit_id(it.targetRefCommit),
          common_commit = commit_id(it.commonRefCommit),
          commits = commits,
        })
      end
      callback(iterations)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Files changed by a pull request up to an iteration (against its merge base):
-- callback({ { path, original_path, change_type } }) sorted by path
function M.iteration_changes(repo, id, iteration_id, callback)
  local changes = {}
  local function fetch(skip)
    client.get(pr_path(repo, id, "/iterations/" .. iteration_id .. "/changes?$compareTo=0&$top=2000&$skip=" .. skip
      .. "&api-version=7.1"), {
      on_success = function(data)
        data = data or {}
        for _, c in ipairs(type(data.changeEntries) == "table" and data.changeEntries or {}) do
          strip_nulls(c)
          local item = type(c.item) == "table" and strip_nulls(c.item) or {}
          if item.path and item.isFolder ~= true and item.gitObjectType ~= "tree" then
            table.insert(changes, {
              path = item.path,
              original_path = c.originalPath or item.originalPath,
              change_type = c.changeType or "edit",
            })
          end
        end
        if type(data.nextSkip) == "number" and data.nextSkip > 0 then
          return fetch(data.nextSkip)
        end
        table.sort(changes, function(a, b)
          return a.path:lower() < b.path:lower()
        end)
        callback(changes)
      end,
      on_error = function(err)
        callback(nil, err)
      end,
    })
  end
  fetch(0)
end

-- Commits of a pull request, newest first
function M.commits(repo, id, callback)
  client.get(pr_path(repo, id, "/commits?$top=500&api-version=7.1"), {
    on_success = function(data)
      local commits = {}
      for _, c in ipairs(data and data.value or {}) do
        strip_nulls(c)
        local author = type(c.author) == "table" and c.author or {}
        table.insert(commits, {
          id = c.commitId,
          author = author.name,
          date = author.date,
          message = c.comment or "",
        })
      end
      callback(commits)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Content of a file at a commit: callback(text), callback(nil, "binary") or callback(nil, err)
function M.file_at_commit(repo, path, sha, callback)
  client.get(repo_path(repo, "items?path=" .. url_encode(path) .. "&versionDescriptor.version=" .. sha
    .. "&versionDescriptor.versionType=commit&includeContent=true&api-version=7.1"), {
    silent = true,
    on_success = function(data)
      data = data or {}
      local meta = type(data.contentMetadata) == "table" and data.contentMetadata or {}
      if meta.isBinary == true then
        return callback(nil, "binary")
      end
      callback(type(data.content) == "string" and data.content or "")
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Id of the user the PAT belongs to (votes and auto-complete need it), fetched once
local me_id
function M.me(callback)
  if me_id then
    return callback(me_id)
  end
  client.get("/_apis/connectionData", {
    on_success = function(data)
      local user = data and data.authenticatedUser
      me_id = type(user) == "table" and user.id or nil
      callback(me_id, not me_id and "no authenticated user" or nil)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Cast the current user's vote (adds them as a reviewer when they are not one yet)
function M.vote(repo, id, vote, callback)
  M.me(function(me, err)
    if not me then
      return callback(nil, err)
    end
    client.request({
      path = pr_path(repo, id, "/reviewers/" .. me .. "?api-version=7.1"),
      method = "PUT",
      body = { vote = vote },
      on_success = function()
        callback(true)
      end,
      on_error = function(err2)
        callback(nil, err2)
      end,
    })
  end)
end

-- Update a pull request (status, auto-complete, completion options); callback(pr)
local function update(repo, id, body, callback)
  client.request({
    path = pr_path(repo, id, "?api-version=7.1"),
    method = "PATCH",
    body = body,
    on_success = function(data)
      callback(data and map_pr(repo, data) or true)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

local function completion_options(opts)
  return {
    mergeStrategy = opts.merge_strategy,
    deleteSourceBranch = opts.delete_source_branch,
    transitionWorkItems = opts.transition_work_items,
  }
end

-- Complete (merge) a pull request now. opts: { merge_strategy, delete_source_branch,
-- transition_work_items }
function M.complete(repo, pr, opts, callback)
  update(repo, pr.id, {
    status = "completed",
    lastMergeSourceCommit = { commitId = pr.last_merge_source_commit },
    completionOptions = completion_options(opts),
  }, callback)
end

-- Let the pull request complete by itself once its policies pass (opts as in complete)
function M.set_auto_complete(repo, pr, opts, callback)
  M.me(function(me, err)
    if not me then
      return callback(nil, err)
    end
    update(repo, pr.id, { autoCompleteSetBy = { id = me }, completionOptions = completion_options(opts) }, callback)
  end)
end

function M.cancel_auto_complete(repo, pr, callback)
  update(repo, pr.id, { autoCompleteSetBy = { id = "00000000-0000-0000-0000-000000000000" } }, callback)
end

-- Builds of a pull request (those run on its merge ref), the latest of each pipeline, sorted
-- by pipeline name: callback(runs). opts.silent suppresses error notifications (used while polling)
function M.builds(repo, id, callback, opts)
  client.get("/" .. repo.project.id .. "/_apis/build/builds?branchName=refs/pull/" .. id .. "/merge"
    .. "&repositoryId=" .. repo.id .. "&repositoryType=TfsGit&queryOrder=queueTimeDescending&$top=100&api-version=7.1", {
    silent = opts and opts.silent,
    on_success = function(data)
      local runs, seen = {}, {}
      for _, b in ipairs(data and data.value or {}) do
        local run = builds_api.map_run(b)
        -- Newest first: the first run of each pipeline is its latest
        local key = run.definition_id or run.id
        if not seen[key] then
          seen[key] = true
          table.insert(runs, run)
        end
      end
      table.sort(runs, function(a, b)
        return (a.definition_name or ""):lower() < (b.definition_name or ""):lower()
      end)
      callback(runs)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Votes, best first, as offered when voting
M.votes = {
  { value = 10, label = "Approve" },
  { value = 5, label = "Approve with suggestions" },
  { value = 0, label = "Reset feedback" },
  { value = -5, label = "Wait for author" },
  { value = -10, label = "Reject" },
}

local vote_display = {
  [10] = { "Approved", "succeeded", "WorkhorsePRApproved" },
  [5] = { "Approved with suggestions", "succeeded", "WorkhorsePRApproved" },
  [0] = { "No vote", "pending", "WorkhorseBuildPending" },
  [-5] = { "Waiting for author", "partiallySucceeded", "WorkhorsePRWaiting" },
  [-10] = { "Rejected", "failed", "WorkhorsePRRejected" },
}

-- Label, icon and highlight of a reviewer's vote
function M.vote_display(vote)
  local d = vote_display[vote] or vote_display[0]
  local icon = builds_api.status_icon(d[2] == "pending" and "notStarted" or "completed", d[2])
  return d[1], icon, d[3]
end

-- Nerd Font git icons
local PR_OPEN = vim.fn.nr2char(0xf407) -- nf-oct-git_pull_request
local PR_MERGED = vim.fn.nr2char(0xf419) -- nf-oct-git_merge
local PR_CLOSED = vim.fn.nr2char(0xf4dc) -- nf-oct-git_pull_request_closed
local PR_DRAFT = vim.fn.nr2char(0xf4dd) -- nf-oct-git_pull_request_draft

-- Icon and highlight of a pull request's status
function M.status_icon(pr)
  if pr.status == "completed" then
    return PR_MERGED, "WorkhorseBuildSucceeded"
  elseif pr.status == "abandoned" then
    return PR_CLOSED, "WorkhorseBuildCanceled"
  elseif pr.is_draft then
    return PR_DRAFT, "WorkhorsePRDraft"
  end
  return PR_OPEN, "WorkhorseBuildRunning"
end

-- Merge strategies offered when completing, as { value, label }
M.merge_strategies = {
  { value = "squash", label = "Squash commit" },
  { value = "noFastForward", label = "Merge (no fast-forward)" },
  { value = "rebase", label = "Rebase and fast-forward" },
  { value = "rebaseMerge", label = "Semi-linear merge (rebase + merge commit)" },
}

return M
