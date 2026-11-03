-- "New pull request" forms of the pull request list, on the form engine of the build forms
-- (builds/form.lua: "name: value" lines in a float, <Tab>/<S-Tab> between the values, choices
-- shown while typing, <CR> or <leader><leader> submits after a confirmation). Two modes:
--
--   simple (<leader>wn)  like the web's "New pull request": source and target branches
--                        (completed from the repository's), a title (by default the last commit
--                        message of the source branch) and an optional work item to link
--   script (<leader>wN)  the flow of Criar-PullRequest.ps1, in a clone of the repository: push the
--                        source branch (the current one) with --set-upstream, create the pull
--                        request linked to a work item (its title by default), set how it
--                        completes (merge commit message "PR <id>: <title>", auto-complete,
--                        deleting the source branch) and optionally approve it
--
-- The work item completes like the Work Items section of a pull request (prs/work_items.lua):
-- from prs.work_items_query or the last query opened; an id typed by hand is looked up when
-- leaving insert mode.
local M = {}

local prs_api = require("workhorse.api.pullrequests")
local forms = require("workhorse.builds.form")
local work_items = require("workhorse.prs.work_items")
local config = require("workhorse.config")
local async = require("workhorse.async")

local ns = vim.api.nvim_create_namespace("workhorse_new_pr")

local KEYS = {
  title = "Title",
  work_item = "Work item",
  source = "Source branch",
  target = "Target branch",
  push = "Push",
  auto_complete = "Auto-complete",
  merge_strategy = "Merge strategy",
  delete_source = "Delete source branch",
  approve = "Approve",
}

-- Fields of each mode, in order
local ORDER = {
  simple = { "source", "target", "title", "work_item" },
  script = { "title", "work_item", "source", "target", "push", "auto_complete", "merge_strategy", "delete_source",
    "approve" },
}

local BOOLEANS = { push = true, auto_complete = true, delete_source = true, approve = true }

local FIELD_BY_KEY = {}
for id, key in pairs(KEYS) do
  FIELD_BY_KEY[key:lower()] = id
end

local APPROVE = 10

-- Form state (see forms.get): { prev, repo, mode, remote, dir, current_branch, default_branch,
-- branches (names, nil while loading), subjects = { [branch] = text, "loading" or false },
-- looked_up = { [id] = true }, creating, on_created }

local function short_branch(ref)
  return ((ref or ""):gsub("^refs/heads/", ""))
end

local function hint(text, hl)
  return { "  " .. text, hl or "WorkhorseRunHint" }
end

--- Parse the form lines (the title first) into { [field id] = value, lnums = { [field id] = lnum },
--- unknown = { "line" } }
function M.parse_lines(lines)
  local result = { lnums = {}, unknown = {} }
  for lnum, line in ipairs(lines) do
    if lnum > 1 and not line:match("^%s*$") and not line:match("^#") then
      local key, value = line:match("^([^:]+):%s?(.*)$")
      local id = key and FIELD_BY_KEY[vim.trim(key):lower()]
      if id then
        result[id] = vim.trim(value)
        result.lnums[id] = lnum
      else
        table.insert(result.unknown, line)
      end
    end
  end
  return result
end

local function parse(bufnr)
  return M.parse_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
end

--- Id of the work item of a "Work item" value ("1234", "#1234" or "#1234 | Title"): a number,
--- nil when empty, false when it is not one of these
local function work_item_id(value)
  if (value or "") == "" then
    return nil
  end
  local id = value:match("^#?(%d+)%s*$") or value:match("^#?(%d+)%s*|")
  return id and tonumber(id) or false
end

local function bool(value)
  value = (value or ""):lower()
  if value == "yes" or value == "y" or value == "true" then
    return true
  elseif value == "no" or value == "n" or value == "false" then
    return false
  end
end

local function strategy(value)
  for _, s in ipairs(prs_api.merge_strategies) do
    if s.value:lower() == (value or ""):lower() then
      return s
    end
  end
end

local function has_branch(form, name)
  return form.branches and vim.tbl_contains(form.branches, name)
end

-- Loading ---------------------------------------------------------------------

-- Fetch the last commit message of a branch (the default title of the simple form), once
local function load_subject(bufnr, branch)
  local form = forms.get(bufnr)
  if not form or form.mode ~= "simple" or form.subjects[branch] ~= nil or not has_branch(form, branch) then
    return
  end
  form.subjects[branch] = "loading"
  prs_api.last_commit_subject(form.repo, branch, function(subject)
    if forms.get(bufnr) ~= form then
      return
    end
    form.subjects[branch] = subject or false
    form.spec.decorate(bufnr)
  end)
end

-- The value of the work item line, completed to "#id | title" when the work item is known
local function complete_work_item(bufnr)
  local parsed = parse(bufnr)
  local id, lnum = work_item_id(parsed.work_item), parsed.lnums.work_item
  local item = id and work_items.info(id)
  if not item or item.title == "" then
    return
  end
  local text = ("%s: #%d | %s"):format(KEYS.work_item, id, item.title)
  if vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] ~= text then
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { text })
  end
end

-- Look up the typed work item when it is not known (on leaving insert mode)
local function lookup_work_item(bufnr)
  local form = forms.get(bufnr)
  local id = work_item_id(parse(bufnr).work_item)
  if not form or not id then
    return
  end
  local item, missing, fetching = work_items.info(id)
  if item then
    return complete_work_item(bufnr)
  elseif missing or fetching then
    return
  end
  work_items.lookup({ id }, function()
    if forms.get(bufnr) ~= form then
      return
    end
    -- Not while typing: leaving insert mode completes it again
    if not vim.fn.mode():match("^[iR]") then
      complete_work_item(bufnr)
    end
    form.spec.decorate(bufnr)
  end)
  form.spec.decorate(bufnr)
end

-- Completion ------------------------------------------------------------------

local function field_at(parsed, lnum)
  for id, l in pairs(parsed.lnums) do
    if l == lnum then
      return id
    end
  end
end

local function field_choices(bufnr, lnum)
  local form = forms.get(bufnr)
  local field = field_at(parse(bufnr), lnum)
  if field == "source" or field == "target" then
    return form.branches or {}
  elseif field == "work_item" then
    return work_items.choices()
  elseif field == "merge_strategy" then
    return vim.tbl_map(function(s)
      return s.value
    end, prs_api.merge_strategies)
  elseif field and BOOLEANS[field] then
    return { "yes", "no" }
  end
  return nil
end

-- Decoration ------------------------------------------------------------------

-- The title the pull request gets when the field is empty, nil when there is none (yet)
local function default_title(form, parsed)
  if form.mode == "script" then
    local id = work_item_id(parsed.work_item)
    local item = id and work_items.info(id)
    return item and item.title ~= "" and item.title or nil
  end
  local subject = form.subjects[parsed.source or ""]
  return type(subject) == "string" and subject ~= "" and subject or nil
end

local function field_hints(form, parsed)
  local hints = {}
  local required = function(text)
    return { hint(text or "required", "WorkhorseRunRequired") }
  end

  if (parsed.title or "") == "" then
    local default = default_title(form, parsed)
    if default then
      hints.title = { hint("defaults to: " .. default) }
    elseif form.mode == "script" then
      hints.title = { hint("defaults to the title of the work item") }
    elseif form.subjects[parsed.source or ""] == "loading" then
      hints.title = { hint("loading the last commit of " .. parsed.source .. "…") }
    else
      hints.title = required()
    end
  end

  local id = work_item_id(parsed.work_item)
  if id == nil then
    hints.work_item = form.mode == "script" and required() or { hint("optional: a work item to link") }
  elseif id == false then
    hints.work_item = required("not a '#id | title' value")
  else
    local item, missing, fetching = work_items.info(id)
    if fetching then
      hints.work_item = { hint("looking up…") }
    elseif missing then
      hints.work_item = required("work item not found")
    elseif item and item.hidden then
      hints.work_item = { hint("not readable with this PAT") }
    elseif item and item.board_column ~= "" then
      hints.work_item = { hint(item.board_column, (config.get().column_colors or {})[item.board_column]) }
    end
  end

  local push = form.mode == "script" and bool(parsed.push)
  local source = parsed.source or ""
  if source == "" then
    hints.source = required()
  elseif not form.branches then
    hints.source = { hint("loading branches…") }
  elseif push then
    hints.source = { hint("pushed to " .. form.remote .. " first") }
  elseif not has_branch(form, source) then
    hints.source = required("not on the server")
  elseif source == form.current_branch then
    hints.source = { hint("current branch") }
  end

  local target = parsed.target or ""
  if target == "" then
    hints.target = required()
  elseif target == source then
    hints.target = required("same as the source branch")
  elseif form.branches and not has_branch(form, target) then
    hints.target = required("unknown branch")
  elseif target == form.default_branch then
    hints.target = { hint("default branch") }
  end

  for field in pairs(BOOLEANS) do
    if bool(parsed[field]) == nil then
      hints[field] = required("yes or no")
    end
  end
  if push then
    hints.push = { hint("git push --set-upstream " .. form.remote .. " " .. (source ~= "" and source or "<branch>")) }
  end
  if bool(parsed.auto_complete) then
    hints.auto_complete = { hint("completes once the policies pass") }
  end
  if bool(parsed.approve) then
    hints.approve = { hint("votes Approve") }
  end
  local s = strategy(parsed.merge_strategy)
  hints.merge_strategy = s and { hint(s.label) } or required("squash, noFastForward, rebase or rebaseMerge")
  return hints
end

local function decorate(bufnr)
  local form = forms.get(bufnr)
  if not form then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local parsed = M.parse_lines(lines)
  local hints = field_hints(form, parsed)
  for lnum, line in ipairs(lines) do
    local row = lnum - 1
    if lnum == 1 then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { end_col = #line, hl_group = "WorkhorseBuildHeader" })
    elseif line:match("^#") then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { end_col = #line, hl_group = "WorkhorseRunHint" })
    else
      local key = line:match("^([^:#][^:]*):")
      if key then
        vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { end_col = #key + 1, hl_group = "WorkhorseRunKey" })
        local id = FIELD_BY_KEY[vim.trim(key):lower()]
        if id and hints[id] and parsed.lnums[id] == lnum then
          vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { virt_text = hints[id] })
        end
      end
    end
  end
end

local function on_change(bufnr)
  load_subject(bufnr, parse(bufnr).source or "")
end

-- Submit ----------------------------------------------------------------------

-- What to create, or nil and a list of errors, or nil, nil and the id of a work item to look up
local function collect(form, parsed)
  local errors = {}
  for _, line in ipairs(parsed.unknown) do
    table.insert(errors, "Not a 'name: value' line: " .. line)
  end
  local script = form.mode == "script"
  local result = { source = parsed.source or "", target = parsed.target or "" }

  for field in pairs(BOOLEANS) do
    if parsed.lnums[field] then
      result[field] = bool(parsed[field])
      if result[field] == nil then
        table.insert(errors, KEYS[field] .. " must be yes or no")
      end
    end
  end
  if script then
    local s = strategy(parsed.merge_strategy)
    result.merge_strategy = s and s.value
    if not s then
      table.insert(errors, "Unknown merge strategy: " .. (parsed.merge_strategy or ""))
    end
  end

  if result.source == "" then
    table.insert(errors, "Source branch is empty")
  elseif form.branches and not result.push and not has_branch(form, result.source) then
    table.insert(errors, "Source branch " .. result.source .. " is not on the server")
  end
  if result.target == "" then
    table.insert(errors, "Target branch is empty")
  elseif result.target == result.source then
    table.insert(errors, "Source and target are the same branch")
  elseif form.branches and not has_branch(form, result.target) then
    table.insert(errors, "Unknown target branch: " .. result.target)
  end

  local id = work_item_id(parsed.work_item)
  if id == nil then
    if script then
      table.insert(errors, "Work item is empty")
    end
  elseif id == false then
    table.insert(errors, "Work item is not a '#id | title' value: " .. parsed.work_item)
  else
    local item, missing, fetching = work_items.info(id)
    if fetching then
      table.insert(errors, "Work item #" .. id .. " is still being looked up")
    elseif missing then
      table.insert(errors, "Work item #" .. id .. " not found")
    elseif not item then
      if form.looked_up[id] then
        table.insert(errors, "Could not look up work item #" .. id)
      elseif #errors == 0 then
        return nil, nil, id
      end
    end
    result.work_item = id
  end

  result.title = (parsed.title or "") ~= "" and parsed.title or default_title(form, parsed)
  if not result.title then
    table.insert(errors, form.subjects[result.source] == "loading"
      and "Title is empty (the last commit of the source branch is still loading)" or "Title is empty")
  end

  if #errors > 0 then
    return nil, errors
  end
  return result
end

-- The confirmation of what submitting does
local function summary(form, opts)
  local lines = {}
  if opts.push then
    table.insert(lines, ("Push %s to %s"):format(opts.source, form.remote))
  end
  table.insert(lines, ("Create pull request %s → %s: %s%s"):format(opts.source, opts.target, opts.title,
    opts.work_item and (" (#" .. opts.work_item .. ")") or ""))
  if form.mode == "script" then
    table.insert(lines, ("%s with %s%s, merge commit \"PR <id>: %s\""):format(
      opts.auto_complete and "Auto-complete" or "Complete", opts.merge_strategy,
      opts.delete_source and (", deleting " .. opts.source) or "", opts.title))
    if opts.approve then
      table.insert(lines, "Approve it")
    end
  end
  return table.concat(lines, "\n")
end

--- Create the pull request described by the form, after a confirmation
function M.submit(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local form = forms.get(bufnr)
  if not form then
    return
  end
  if form.creating then
    vim.notify("Workhorse: Already creating this pull request", vim.log.levels.INFO)
    return
  end
  local opts, errors, lookup = collect(form, parse(bufnr))
  if lookup then
    -- A typed id not looked up yet: look it up, then submit again
    form.looked_up[lookup] = true
    work_items.lookup({ lookup }, function()
      if forms.get(bufnr) == form then
        complete_work_item(bufnr)
        decorate(bufnr)
        M.submit(bufnr)
      end
    end)
    return
  end
  if not opts then
    vim.notify("Workhorse: Cannot create the pull request:\n  " .. table.concat(errors, "\n  "), vim.log.levels.ERROR)
    return
  end
  if vim.fn.confirm(summary(form, opts) .. "?", "&Create\n&Cancel", 1) ~= 1 then
    return
  end

  form.creating = true
  local repo = form.repo
  local progress = require("workhorse.progress").start("Creating pull request")
  local warnings = {}
  local function fail(what, err)
    progress(true)
    form.creating = false
    err = vim.trim(err or "")
    vim.notify(("Workhorse: Failed to %s: %s"):format(what, err ~= "" and err or "unknown error"), vim.log.levels.ERROR)
  end
  local function finish(pr)
    progress(#warnings > 0)
    local msg = "Workhorse: Created pull request !" .. pr.id .. " " .. pr.title
    if #warnings > 0 then
      vim.notify(msg .. ", but:\n  " .. table.concat(warnings, "\n  "), vim.log.levels.WARN)
    else
      vim.notify(msg, vim.log.levels.INFO)
    end
    forms.close(bufnr)
    if form.on_created then
      form.on_created(pr)
    end
  end

  -- The steps, in order; each one calls next(pr) when done
  local function approve(pr)
    if not opts.approve then
      return finish(pr)
    end
    prs_api.vote(repo, pr.id, APPROVE, function(ok, err)
      if not ok then
        table.insert(warnings, "approving failed: " .. (err or "unknown error"))
      end
      finish(pr)
    end)
  end
  local function completion(pr)
    if form.mode ~= "script" then
      return finish(pr)
    end
    local set = opts.auto_complete and prs_api.set_auto_complete or prs_api.set_completion_options
    set(repo, pr, {
      merge_strategy = opts.merge_strategy,
      delete_source_branch = opts.delete_source,
      transition_work_items = config.get().prs.transition_work_items,
      merge_commit_message = ("PR %d: %s"):format(pr.id, opts.title),
    }, function(updated, err)
      if not updated then
        table.insert(warnings, (opts.auto_complete and "setting auto-complete" or "setting the completion options")
          .. " failed: " .. (err or "unknown error"))
      end
      approve(type(updated) == "table" and updated or pr)
    end)
  end
  local function create()
    prs_api.create(repo, {
      source_branch = opts.source,
      target_branch = opts.target,
      title = opts.title,
      work_item_ids = opts.work_item and { opts.work_item } or nil,
    }, function(pr, err)
      if not pr then
        return fail("create the pull request", err)
      end
      completion(pr)
    end)
  end
  if not opts.push then
    return create()
  end
  -- No terminal to ask for credentials in: fail instead of waiting for an answer
  async.exec("git", { "-C", form.dir, "push", "--set-upstream", form.remote, opts.source }, function(_, err, code)
    if code ~= 0 then
      return fail("push " .. opts.source, err)
    end
    create()
  end, nil, { GIT_TERMINAL_PROMPT = "0" })
end

-- Open ------------------------------------------------------------------------

local TITLES = {
  simple = "New pull request",
  script = "New pull request (Criar-PullRequest)",
}

--- Open the form to create a pull request on `repo` ({ id, name, project = { id, name },
--- default_branch? }). opts:
---   mode         "simple" (default) or "script" (needs remote and dir)
---   remote, dir  git remote of a clone of the repository and the clone's directory: the source
---                branch starts as the clone's current branch
---   on_created(pr)  called once the pull request is created (the form is closed then)
function M.open(repo, opts)
  opts = opts or {}
  local mode = opts.mode == "script" and "script" or "simple"
  local current_branch
  if opts.dir then
    local out = vim.fn.systemlist({ "git", "-C", opts.dir, "branch", "--show-current" })
    current_branch = vim.v.shell_error == 0 and out[1] and out[1] ~= "" and out[1] or nil
  end
  local cfg = config.get().prs
  local default_branch = repo.default_branch and short_branch(repo.default_branch) or nil
  local values = {
    title = "",
    work_item = "",
    source = current_branch or "",
    target = default_branch or "",
    push = "yes",
    auto_complete = "yes",
    merge_strategy = cfg.merge_strategy or "squash",
    delete_source = "yes",
    approve = "no",
  }
  local lines = { TITLES[mode] .. ": " .. repo.name }
  for _, id in ipairs(ORDER[mode]) do
    table.insert(lines, KEYS[id] .. ": " .. values[id])
  end
  table.insert(lines, "")

  local form = {
    prev = vim.api.nvim_get_current_buf(),
    repo = repo,
    mode = mode,
    remote = opts.remote,
    dir = opts.dir,
    current_branch = current_branch,
    default_branch = default_branch,
    subjects = {},
    looked_up = {},
    on_created = opts.on_created,
  }
  local spec = {
    title = " Workhorse: " .. TITLES[mode]:lower() .. " ",
    submit_desc = "create the pull request",
    choices = field_choices,
    decorate = decorate,
    on_change = on_change,
    submit = function(b)
      M.submit(b)
    end,
  }
  local bufnr = forms.create(spec, form, "Workhorse|new-pr", lines)
  -- Start on the first empty value: the title (script), the source branch or the title (simple)
  local row
  for i, id in ipairs(ORDER[mode]) do
    if not row and values[id] == "" then
      row = i + 1
    end
  end
  row = row or 2
  forms.show(bufnr, { row, #lines[row] })

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = vim.api.nvim_create_augroup("workhorse_new_pr_" .. bufnr, { clear = true }),
    buffer = bufnr,
    callback = function()
      lookup_work_item(bufnr)
    end,
  })

  local function alive()
    return forms.get(bufnr) == form
  end
  prs_api.branches(repo, function(branches)
    if not alive() then
      return
    end
    form.branches = branches or {}
    on_change(bufnr)
    decorate(bufnr)
    forms.refresh_completion(bufnr)
  end)
  if not default_branch then
    prs_api.default_branch(repo, function(ref)
      if not alive() or not ref then
        return
      end
      form.default_branch = short_branch(ref)
      local parsed = parse(bufnr)
      local lnum = parsed.lnums.target
      if lnum and (parsed.target or "") == "" then
        vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { KEYS.target .. ": " .. form.default_branch })
      end
      decorate(bufnr)
    end)
  end
  work_items.load_list(function()
    if alive() then
      forms.refresh_completion(bufnr)
    end
  end)
  return bufnr
end

return M
