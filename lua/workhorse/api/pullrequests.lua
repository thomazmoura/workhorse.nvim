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

-- Web page of a build of the repository's project
function M.build_url(repo, build_id)
  local server = (config.get().server_url or ""):gsub("/$", "")
  return server .. "/" .. url_encode(repo.project.name) .. "/_build/results?buildId=" .. build_id
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
    created_by_id = type(p.createdBy) == "table" and p.createdBy.id or nil,
    creation_date = p.creationDate,
    closed_date = p.closedDate,
    source_ref = p.sourceRefName,
    target_ref = p.targetRefName,
    merge_status = p.mergeStatus,
    auto_complete_set_by = display_name(p.autoCompleteSetBy),
    reviewers = reviewers,
    last_merge_source_commit = commit_id(p.lastMergeSourceCommit),
    -- Once completed: the commit the merge left on the target branch
    last_merge_commit = commit_id(p.lastMergeCommit),
    completion_options = {
      merge_strategy = options.mergeStrategy,
      delete_source_branch = options.deleteSourceBranch,
    },
    url = M.pr_url(repo, p.pullRequestId),
  }
end

-- Git repositories of every project the PAT can see: callback({ { id, name, project = { id,
-- name }, default_branch, web_url, remote_url, ssh_url } }) sorted by project then name, disabled
-- ones left out
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
            -- Clone URLs, to find the repository of a local checkout (see workhorse.repos)
            remote_url = r.remoteUrl,
            ssh_url = r.sshUrl,
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

-- Branches of a repository (names without refs/heads/), sorted: callback(names) or (nil, err)
function M.branches(repo, callback)
  client.get(repo_path(repo, "refs?filter=heads/&api-version=7.1"), {
    on_success = function(data)
      local names = {}
      for _, ref in ipairs(data and data.value or {}) do
        if type(ref) == "table" and type(ref.name) == "string" then
          table.insert(names, (ref.name:gsub("^refs/heads/", "")))
        end
      end
      table.sort(names, function(a, b)
        return a:lower() < b:lower()
      end)
      callback(names)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Default branch of a repository (a ref, "refs/heads/main"), for repositories known without it:
-- callback(ref) or (nil, err)
function M.default_branch(repo, callback)
  if repo.default_branch then
    return callback(repo.default_branch)
  end
  client.get("/" .. repo.project.id .. "/_apis/git/repositories/" .. repo.id .. "?api-version=7.1", {
    on_success = function(data)
      local ref = type(data) == "table" and type(data.defaultBranch) == "string" and data.defaultBranch or nil
      callback(ref, not ref and "the repository has no default branch" or nil)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- First line of the message of the last commit of a branch: callback(text) or (nil, err)
function M.last_commit_subject(repo, branch, callback)
  client.get(repo_path(repo, "commits?searchCriteria.itemVersion.version=" .. url_encode(branch)
    .. "&searchCriteria.$top=1&api-version=7.1"), {
    silent = true,
    on_success = function(data)
      local commit = data and type(data.value) == "table" and data.value[1]
      local comment = type(commit) == "table" and type(commit.comment) == "string" and commit.comment or nil
      callback(comment and vim.trim(comment:match("^[^\r\n]*")) or nil)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Create a pull request. opts: { source_branch, target_branch (names or refs), title,
-- work_item_ids } (the work items get linked to it): callback(pr) or (nil, err)
function M.create(repo, opts, callback)
  local function ref(branch)
    return branch:match("^refs/") and branch or ("refs/heads/" .. branch)
  end
  local work_items = {}
  for _, id in ipairs(opts.work_item_ids or {}) do
    table.insert(work_items, { id = tostring(id) })
  end
  client.request({
    path = repo_path(repo, "pullrequests?api-version=7.1"),
    method = "POST",
    body = {
      sourceRefName = ref(opts.source_branch),
      targetRefName = ref(opts.target_branch),
      title = opts.title,
      workItemRefs = #work_items > 0 and work_items or nil,
    },
    on_success = function(data)
      local pr = type(data) == "table" and data.pullRequestId and map_pr(repo, data) or nil
      callback(pr, not pr and "no pull request in the response" or nil)
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
function M.get(repo, id, callback, opts)
  client.get(pr_path(repo, id, "?api-version=7.1"), {
    silent = opts and opts.silent,
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
function M.threads(repo, id, callback, opts)
  client.get(pr_path(repo, id, "/threads?api-version=7.1"), {
    silent = opts and opts.silent,
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
function M.iterations(repo, id, callback, opts)
  client.get(pr_path(repo, id, "/iterations?includeCommits=true&api-version=7.1"), {
    silent = opts and opts.silent,
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

-- Files changed by a pull request up to an iteration (against its merge base), deleted ones by
-- their original path: callback({ { path, original_path, change_type } }) sorted by path
function M.iteration_changes(repo, id, iteration_id, callback, opts)
  local changes = {}
  local function fetch(skip)
    client.get(pr_path(repo, id, "/iterations/" .. iteration_id .. "/changes?$compareTo=0&$top=2000&$skip=" .. skip
      .. "&api-version=7.1"), {
      silent = opts and opts.silent,
      on_success = function(data)
        data = data or {}
        for _, c in ipairs(type(data.changeEntries) == "table" and data.changeEntries or {}) do
          strip_nulls(c)
          local item = type(c.item) == "table" and strip_nulls(c.item) or {}
          -- Deleted files have no item path: theirs is the original one
          local path = item.path or c.originalPath or item.originalPath
          if path and item.isFolder ~= true and item.gitObjectType ~= "tree" then
            table.insert(changes, {
              path = path,
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
function M.commits(repo, id, callback, opts)
  client.get(pr_path(repo, id, "/commits?$top=500&api-version=7.1"), {
    silent = opts and opts.silent,
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

-- Add a reviewer (a user or group, by identity id), or change whether they are required: the
-- vote is left out of the body, so an existing reviewer's vote stays. callback(true) or (nil, err)
function M.add_reviewer(repo, id, reviewer_id, required, callback)
  client.request({
    path = pr_path(repo, id, "/reviewers/" .. reviewer_id .. "?api-version=7.1"),
    method = "PUT",
    body = { id = reviewer_id, isRequired = required == true },
    on_success = function()
      callback(true)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

function M.remove_reviewer(repo, id, reviewer_id, callback)
  client.request({
    path = pr_path(repo, id, "/reviewers/" .. reviewer_id .. "?api-version=7.1"),
    method = "DELETE",
    on_success = function()
      callback(true)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Ids of the work items linked to a pull request: callback({ id, ... })
function M.work_items(repo, id, callback, opts)
  client.get(pr_path(repo, id, "/workitems?api-version=7.1"), {
    silent = opts and opts.silent,
    on_success = function(data)
      local ids = {}
      for _, ref in ipairs(data and data.value or {}) do
        local wid = tonumber(type(ref) == "table" and ref.id or nil)
        if wid then
          table.insert(ids, wid)
        end
      end
      callback(ids)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Artifact URL of a pull request: the url of the "Pull Request" link of a work item to it
function M.artifact_url(repo, id)
  return ("vstfs:///Git/PullRequestId/%s%%2F%s%%2F%s"):format(repo.project.id, repo.id, id)
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
    mergeCommitMessage = opts.merge_commit_message,
  }
end

-- Complete (merge) a pull request now. opts: { merge_strategy, delete_source_branch,
-- transition_work_items, merge_commit_message (optional) }
function M.complete(repo, pr, opts, callback)
  update(repo, pr.id, {
    status = "completed",
    lastMergeSourceCommit = { commitId = pr.last_merge_source_commit },
    completionOptions = completion_options(opts),
  }, callback)
end

-- Abandon a pull request (only its creator may: see is_creator)
function M.abandon(repo, pr, callback)
  update(repo, pr.id, { status = "abandoned" }, callback)
end

-- callback(true) when the user the PAT belongs to created `pr`; false when not (or unknown)
function M.is_creator(pr, callback)
  if not pr.created_by_id then
    return callback(false)
  end
  M.me(function(me)
    callback(me ~= nil and me:lower() == pr.created_by_id:lower())
  end)
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

-- Set how the pull request completes (opts as in complete) without setting auto-complete
function M.set_completion_options(repo, pr, opts, callback)
  update(repo, pr.id, { completionOptions = completion_options(opts) }, callback)
end

function M.cancel_auto_complete(repo, pr, callback)
  update(repo, pr.id, { autoCompleteSetBy = { id = "00000000-0000-0000-0000-000000000000" } }, callback)
end

-- The latest run of each pipeline among `runs` (newest first), sorted by pipeline name
local function latest_per_pipeline(runs)
  local latest, seen = {}, {}
  for _, run in ipairs(runs) do
    local key = run.definition_id or run.id
    if not seen[key] then
      seen[key] = true
      table.insert(latest, run)
    end
  end
  table.sort(latest, function(a, b)
    return (a.definition_name or ""):lower() < (b.definition_name or ""):lower()
  end)
  return latest
end

-- Builds of a pull request (those run on its merge ref), the latest of each pipeline, sorted
-- by pipeline name: callback(runs). opts.silent suppresses error notifications (used while polling)
function M.builds(repo, id, callback, opts)
  client.get("/" .. repo.project.id .. "/_apis/build/builds?branchName=refs/pull/" .. id .. "/merge"
    .. "&repositoryId=" .. repo.id .. "&repositoryType=TfsGit&queryOrder=queueTimeDescending&$top=100&api-version=7.1", {
    silent = opts and opts.silent,
    on_success = function(data)
      local runs = {}
      for _, b in ipairs(data and data.value or {}) do
        table.insert(runs, builds_api.map_run(b))
      end
      callback(latest_per_pipeline(runs))
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Margin before the completion of a pull request from which its merge builds are searched (the
-- push of the merge commit and the completion are not stamped at the same instant)
local MERGE_BUILDS_MARGIN = 10 * 60

-- `iso` (an ISO 8601 UTC date) moved `seconds` back, in the same format; nil when unparseable
local function iso_minus(iso, seconds)
  local y, mo, d, h, mi, s = (iso or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return nil
  end
  -- os.time reads the fields as local time: `offset` (local time to UTC) turns it into the epoch
  -- of the UTC date, which os.date("!") writes back as UTC
  local t = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false })
  local offset = os.time(os.date("!*t", t)) - t
  return os.date("!%Y-%m-%dT%H:%M:%SZ", t - offset - seconds)
end

-- Builds started by the merge of a completed pull request: those of its target branch whose
-- source is the merge commit, the latest of each pipeline, sorted by pipeline name:
-- callback(runs) ({} for a pull request not completed). opts.silent as in builds
function M.merge_builds(repo, pr, callback, opts)
  local commit = pr.status == "completed" and pr.last_merge_commit
  if not commit or not pr.target_ref then
    return callback({})
  end
  -- Oldest first from just before the completion: the merge builds are among the first runs of
  -- the target branch after it, however long ago the pull request was completed
  local min_time = iso_minus(pr.closed_date, MERGE_BUILDS_MARGIN)
  client.get("/" .. repo.project.id .. "/_apis/build/builds?branchName=" .. url_encode(pr.target_ref)
    .. "&repositoryId=" .. repo.id .. "&repositoryType=TfsGit&queryOrder=queueTimeAscending&$top=200"
    .. (min_time and ("&minTime=" .. url_encode(min_time)) or "") .. "&api-version=7.1", {
    silent = opts and opts.silent,
    on_success = function(data)
      local runs = {}
      for _, b in ipairs(data and data.value or {}) do
        local run = builds_api.map_run(b)
        if run.source_version == commit then
          -- Newest first, for latest_per_pipeline
          table.insert(runs, 1, run)
        end
      end
      callback(latest_per_pipeline(runs))
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Policy types of the checks of a pull request (as in api/policies.lua)
local CHECK_KINDS = {
  ["0609b952-1397-4640-95ec-e00a01b2c241"] = "build",
  ["fa4e907d-c16b-4a4c-9dfa-4906e5d171dd"] = "min_reviewers",
  ["fd2167ab-b0be-447a-8ec8-39368250530e"] = "reviewers",
  ["40e92b44-2fe1-4dd6-b3d8-74a9c21d0c6e"] = "work_items",
  ["c6a1889d-b943-4856-b76f-9e46bb6b0df2"] = "comments",
  ["fa4e907d-c16b-4a4c-9dfa-4916e5d171ab"] = "merge_strategy",
  ["cbdc66da-9728-4af8-aada-9a5a32e4a226"] = "status",
}

-- Name of a check, as the web shows it
local function check_name(kind, settings, context, type_name)
  if kind == "build" then
    local name = settings.displayName or context.buildDefinitionName
    return "Build" .. (name and name ~= "" and (": " .. name) or "")
  elseif kind == "min_reviewers" then
    local count = tonumber(settings.minimumApproverCount) or 1
    return ("At least %d reviewer%s must approve"):format(count, count == 1 and "" or "s")
  elseif kind == "reviewers" then
    return "Required reviewers" .. (type(settings.message) == "string" and settings.message ~= ""
      and (": " .. settings.message) or "")
  elseif kind == "work_items" then
    return "Work items must be linked"
  elseif kind == "comments" then
    return "Comments must be resolved"
  elseif kind == "merge_strategy" then
    return "Merge strategy"
  elseif kind == "status" then
    local name = settings.defaultDisplayName
    if not name or name == "" then
      local genre = settings.statusGenre
      name = (genre and genre ~= "" and (genre .. "/") or "") .. (settings.statusName or "")
    end
    return "Status: " .. (name ~= "" and name or "?")
  end
  return type_name or "Policy"
end

-- Checks of a pull request (the evaluations of the branch policies of its target), the
-- not-applicable ones left out: callback({ { id (the evaluation's), kind, name, status
-- ("approved", "rejected", "running", "queued" or "broken"), blocking, build_id,
-- build_definition_id, expired (a build that is no longer valid: it must be queued again),
-- outdated (a build of an older merge commit), started, completed } }), sorted by name
function M.checks(repo, id, callback, opts)
  local artifact = ("vstfs:///CodeReview/CodeReviewId/%s/%s"):format(repo.project.id, id)
  client.get("/" .. repo.project.id .. "/_apis/policy/evaluations?artifactId=" .. url_encode(artifact)
    .. "&api-version=7.1-preview.1", {
    silent = opts and opts.silent,
    on_success = function(data)
      local checks = {}
      for _, e in ipairs(data and data.value or {}) do
        strip_nulls(e)
        local configuration = type(e.configuration) == "table" and strip_nulls(e.configuration) or {}
        local ptype = type(configuration.type) == "table" and configuration.type or {}
        local settings = type(configuration.settings) == "table" and strip_nulls(configuration.settings) or {}
        local context = type(e.context) == "table" and strip_nulls(e.context) or {}
        if e.status ~= "notApplicable" and configuration.isEnabled ~= false then
          local kind = CHECK_KINDS[ptype.id] or "other"
          table.insert(checks, {
            id = e.evaluationId,
            kind = kind,
            name = check_name(kind, settings, context, ptype.displayName),
            status = e.status,
            blocking = configuration.isBlocking == true,
            build_id = tonumber(context.buildId),
            build_definition_id = tonumber(context.buildDefinitionId or settings.buildDefinitionId),
            expired = context.isExpired == true,
            outdated = context.buildIsNotCurrent == true,
            started = e.startedDate,
            completed = e.completedDate,
          })
        end
      end
      table.sort(checks, function(a, b)
        return a.name:lower() < b.name:lower()
      end)
      callback(checks)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Queue a check again (an expired or failed build policy queues a new build): callback(true) or
-- (nil, err)
function M.requeue_check(repo, evaluation_id, callback)
  client.request({
    path = "/" .. repo.project.id .. "/_apis/policy/evaluations/" .. evaluation_id .. "?api-version=7.1-preview.1",
    method = "PATCH",
    raw_body = "{}",
    silent = true,
    on_success = function()
      callback(true)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- State of a check: its label ("succeeded", "expired", ...), icon and highlight
function M.check_display(check)
  local build = check.kind == "build"
  local label, status, result
  if check.status == "running" then
    label, status = build and "running" or "in progress", "inProgress"
  elseif check.expired then
    label, status, result = "expired", "completed", "partiallySucceeded"
  elseif check.status == "approved" then
    label, status, result = build and "succeeded" or "passed", "completed", "succeeded"
  elseif check.status == "rejected" then
    label, status, result = build and "failed" or "not met", "completed", "failed"
  elseif check.status == "broken" then
    label, status, result = "broken", "completed", "failed"
  elseif build and check.build_id and not check.outdated then
    label, status = "queued", "notStarted"
  elseif build then
    -- A build policy queued by hand (or whose build is of an older commit) waits to be queued
    label, status, result = check.outdated and "outdated" or "not started", "completed", "partiallySucceeded"
  else
    label, status = "pending", "notStarted"
  end
  local icon, hl = builds_api.status_icon(status, result)
  return label, icon, hl
end

-- Whether a check is a build that can be queued again (anything but a build under way)
function M.can_requeue(check)
  return check.kind == "build" and check.status ~= "running"
    and not (check.status == "queued" and check.build_id and not check.expired and not check.outdated)
end

-- Whether a check waits for something to queue it again (expired, failed, never started)
function M.needs_requeue(check)
  return M.can_requeue(check) and check.status ~= "approved" or (check.kind == "build" and check.expired == true)
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
