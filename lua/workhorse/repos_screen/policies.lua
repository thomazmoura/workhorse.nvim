-- Policies section of the repository screen (repos_screen/repo.lua): the branch policies of each
-- branch as editable text. The default branch comes first (even before it exists), then the
-- branches with policies, then the others; a branch's policies are indented under it, and the
-- branches are grouped by folder (one "name/" line per part of their path, each a fold):
--
--   main
--     Minimum reviewers: 2, required, reset on push
--     Linked work items: required
--     Comment resolution: optional
--     Merge types: squash, rebase
--     Build: CI-DIAT, required, automatic, expires 720
--     Reviewer: [GTI]\Revisor Gtracs, required
--   features/
--     new/
--       138
--         Linked work items: required
--       64
--
-- A line with a ":" is a policy (branch names cannot hold one); any other line is a folder
-- (ending with "/") or a branch, named by the folders above it ("features/new/64"). A branch line
-- may also hold the whole name ("features/new/65" at the top level).
--
-- The first four are one per branch ("off", or a missing line, turns one off); Build and Reviewer
-- lines can be added and deleted freely (a reviewer line may name several, joined by " + "). A
-- policy can be required or optional, and "off" at the end of a Build or Reviewer line keeps it
-- disabled. Everything is completed (pipelines from the repository cache, users and groups from
-- the identity cache). Status checks are shown under the branch, read-only. Settings this
-- section does not show (path filters, messages...) are kept. Saving (of the whole screen) shows
-- the changes, then applies them.
local M = {}

local repo_screen = require("workhorse.repos_screen.repo")
local policies_api = require("workhorse.api.policies")
local repos_api = require("workhorse.api.repositories")
local identities = require("workhorse.identities")
local identities_api = require("workhorse.api.identities")
local parse_indent = require("workhorse.buffer_tree.parser").parse_indent
local guides = require("workhorse.buffer_tree.guides")
local fold = require("workhorse.fold")

local ns = vim.api.nvim_create_namespace("workhorse_repo_policies")

local notify = repo_screen.notify

local SECTION = "policies"

-- Lines of the section, the buffer line number before them, and whether the section is there
local function section(bufnr)
  local lines, offset = repo_screen.section_lines(bufnr, SECTION)
  return lines or {}, offset or 0, lines ~= nil
end

-- Policy kinds by line key, in the order they are rendered
local KEYS = {
  { kind = "min_reviewers", key = "Minimum reviewers", single = true },
  { kind = "work_items", key = "Linked work items", single = true },
  { kind = "comments", key = "Comment resolution", single = true },
  { kind = "merge_strategy", key = "Merge types", single = true },
  { kind = "build", key = "Build" },
  { kind = "reviewers", key = "Reviewer" },
}
local KEY_OF, KIND_OF_KEY, ORDER = {}, {}, {}
for i, entry in ipairs(KEYS) do
  KEY_OF[entry.kind] = entry
  KIND_OF_KEY[entry.key:lower()] = entry.kind
  ORDER[entry.kind] = i
end

-- Merge types: option text and setting
local MERGE_TYPES = {
  { text = "squash", setting = "allowSquash" },
  { text = "no fast-forward", setting = "allowNoFastForward" },
  { text = "rebase", setting = "allowRebase" },
  { text = "rebase merge", setting = "allowRebaseMerge" },
}

local DEFAULT_VALID_DURATION = 720

-- Per-buffer state: { repo, branches = { name }, on_server = { [name] = true }, policies =
-- { [branch] = { policy } }, status = { [branch] = { policy } }, definitions = { { id, name,
-- repository_id } }, loading, loaded, saving }
local buffers = {}

local function short(ref)
  return (ref or ""):gsub("^refs/heads/", "")
end

local function setting(policy, name)
  local value = type(policy.settings) == "table" and policy.settings[name] or nil
  return value ~= vim.NIL and value or nil
end

-- Pipelines and identities ----------------------------------------------------

local function definition_by_id(state, id)
  for _, d in ipairs(state.definitions or {}) do
    if d.id == id then
      return d
    end
  end
end

-- The pipeline named `text` ("#123" or a name; the repository's own pipelines first)
local function definition_by_name(state, text)
  local id = text:match("^#(%d+)$")
  if id then
    return definition_by_id(state, tonumber(id)) or { id = tonumber(id), name = text }
  end
  local found
  for _, d in ipairs(state.definitions or {}) do
    if d.name:lower() == text:lower() then
      if d.repository_id == state.repo.id then
        return d
      end
      found = found or d
    end
  end
  return found
end

local function definition_text(state, id)
  local d = definition_by_id(state, id)
  return d and d.name or ("#" .. tostring(id))
end

local function reviewer_text(id)
  local identity = identities.by_id(id)
  return identity and identity.name or id
end

-- Pipeline names for completion: the repository's first
local function definition_names(state)
  local own, others = {}, {}
  for _, d in ipairs(state.definitions or {}) do
    table.insert(d.repository_id == state.repo.id and own or others, d.name)
  end
  return vim.list_extend(own, others)
end

-- Policies as text ------------------------------------------------------------

local function requirement(blocking)
  return blocking and "required" or "optional"
end

-- Value of a policy's line (the same text for the same policy, so lines are compared as text)
local function value_text(state, policy)
  local kind = policy.kind
  if kind == "min_reviewers" then
    if not policy.enabled then
      return "off"
    end
    local parts = { tostring(setting(policy, "minimumApproverCount") or 1), requirement(policy.blocking) }
    if setting(policy, "creatorVoteCounts") then
      table.insert(parts, "creator vote counts")
    end
    if setting(policy, "allowDownvotes") then
      table.insert(parts, "allow downvotes")
    end
    if setting(policy, "resetOnSourcePush") then
      table.insert(parts, "reset on push")
    end
    return table.concat(parts, ", ")
  elseif kind == "work_items" or kind == "comments" then
    return policy.enabled and requirement(policy.blocking) or "off"
  elseif kind == "merge_strategy" then
    local parts = {}
    for _, m in ipairs(MERGE_TYPES) do
      if setting(policy, m.setting) then
        table.insert(parts, m.text)
      end
    end
    return (policy.enabled and #parts > 0) and table.concat(parts, ", ") or "off"
  elseif kind == "build" then
    local duration = setting(policy, "validDuration") or 0
    local parts = {
      definition_text(state, setting(policy, "buildDefinitionId")),
      requirement(policy.blocking),
      setting(policy, "manualQueueOnly") and "manual" or "automatic",
      duration == 0 and "never expires" or ("expires " .. math.floor(duration)),
    }
    if not policy.enabled then
      table.insert(parts, "off")
    end
    return table.concat(parts, ", ")
  elseif kind == "reviewers" then
    local names = vim.tbl_map(reviewer_text, setting(policy, "requiredReviewerIds") or {})
    local parts = { table.concat(names, " + "), requirement(policy.blocking) }
    if not policy.enabled then
      table.insert(parts, "off")
    end
    return table.concat(parts, ", ")
  end
  return ""
end

local function line_text(state, policy)
  return KEY_OF[policy.kind].key .. ": " .. value_text(state, policy)
end

-- What a line asks for: { kind, enabled, blocking, fields = { [setting] = value }, key = match
-- key of Build/Reviewer lines } or nil and an error
local function parse_value(state, kind, value)
  local items = {}
  for item in (value .. ","):gmatch("([^,]*),") do
    item = vim.trim(item)
    if item ~= "" then
      table.insert(items, item)
    end
  end
  local spec = { kind = kind, enabled = true, blocking = true, fields = {} }
  local function options(from, allowed)
    for i = from, #items do
      local option = items[i]:lower()
      if option == "required" or option == "optional" then
        spec.blocking = option == "required"
      elseif option == "off" and allowed.off then
        spec.enabled = false
      elseif allowed[option] then
        allowed[option](option)
      else
        local handled = false
        for pattern, fn in pairs(allowed) do
          if type(pattern) == "string" and pattern:sub(1, 1) == "^" and option:match(pattern) then
            fn(option)
            handled = true
          end
        end
        if not handled then
          return nil, "unknown option " .. items[i]
        end
      end
    end
    return true
  end

  if kind == "min_reviewers" then
    if (items[1] or "off"):lower() == "off" then
      spec.enabled = false
      return spec
    end
    local count = tonumber(items[1])
    if not count or count < 1 then
      return nil, "Minimum reviewers starts with a number (or is off)"
    end
    spec.fields = { minimumApproverCount = count, creatorVoteCounts = false, allowDownvotes = false,
      resetOnSourcePush = false }
    local ok, err = options(2, {
      ["creator vote counts"] = function()
        spec.fields.creatorVoteCounts = true
      end,
      ["allow downvotes"] = function()
        spec.fields.allowDownvotes = true
      end,
      ["reset on push"] = function()
        spec.fields.resetOnSourcePush = true
      end,
    })
    if not ok then
      return nil, err
    end
  elseif kind == "work_items" or kind == "comments" then
    local option = (items[1] or "off"):lower()
    if #items > 1 or (option ~= "off" and option ~= "required" and option ~= "optional") then
      return nil, KEY_OF[kind].key .. " is required, optional or off"
    end
    spec.enabled = option ~= "off"
    spec.blocking = option ~= "optional"
  elseif kind == "merge_strategy" then
    if (items[1] or "off"):lower() == "off" then
      spec.enabled = false
      return spec
    end
    for _, m in ipairs(MERGE_TYPES) do
      spec.fields[m.setting] = false
    end
    for _, item in ipairs(items) do
      local found
      for _, m in ipairs(MERGE_TYPES) do
        if m.text == item:lower() then
          found = m
        end
      end
      if not found then
        return nil, "unknown merge type " .. item
      end
      spec.fields[found.setting] = true
    end
  elseif kind == "build" then
    local definition = items[1] and definition_by_name(state, items[1])
    if not definition then
      return nil, "unknown pipeline " .. tostring(items[1] or "")
    end
    spec.fields = { buildDefinitionId = definition.id, manualQueueOnly = false,
      validDuration = DEFAULT_VALID_DURATION }
    spec.key = "build:" .. definition.id
    local ok, err = options(2, {
      off = true,
      automatic = function()
        spec.fields.manualQueueOnly = false
      end,
      manual = function()
        spec.fields.manualQueueOnly = true
      end,
      ["never expires"] = function()
        spec.fields.validDuration = 0
      end,
      ["^expires %d+$"] = function(option)
        spec.fields.validDuration = tonumber(option:match("%d+"))
      end,
    })
    if not ok then
      return nil, err
    end
  elseif kind == "reviewers" then
    local ids = {}
    for name in ((items[1] or "") .. "+"):gmatch("([^+]*)%+") do
      name = vim.trim(name)
      if name ~= "" then
        local identity = identities.by_name(name)
        local id = identity and identity.id or (name:match("^%x+%-%x+%-%x+%-%x+%-%x+$") and name)
        if not id then
          return nil, "unknown user or group " .. name
        end
        table.insert(ids, id)
      end
    end
    if #ids == 0 then
      return nil, "Reviewer names a user or group"
    end
    spec.fields = { requiredReviewerIds = ids }
    local sorted = vim.deepcopy(ids)
    table.sort(sorted)
    spec.key = "reviewers:" .. table.concat(sorted, ",")
    local ok, err = options(2, { off = true })
    if not ok then
      return nil, err
    end
  end
  return spec
end

-- The policy a spec makes, from the original (its settings kept) or new on `branch`
local function policy_of(state, spec, branch, original)
  local settings = original and vim.deepcopy(original.settings) or { scope = policies_api.scope(state.repo.id, branch) }
  if not original then
    if spec.kind == "build" then
      settings.queueOnSourceUpdateOnly = true
    elseif spec.kind == "reviewers" then
      settings.minimumApproverCount = 1
      settings.creatorVoteCounts = false
    end
  end
  for key, value in pairs(spec.fields) do
    settings[key] = value
  end
  return {
    id = original and original.id,
    kind = spec.kind,
    enabled = spec.enabled,
    -- Merge types can't be optional
    blocking = spec.kind == "merge_strategy" or spec.blocking,
    settings = settings,
  }
end

-- Rendering -------------------------------------------------------------------

local function sorted_policies(list)
  table.sort(list, function(a, b)
    if a.kind ~= b.kind then
      return ORDER[a.kind] < ORDER[b.kind]
    end
    return a.id < b.id
  end)
  return list
end

-- Branches grouped by folder: { children = { { name = "features/", children } | { name = "64",
-- branch = "features/new/64" } } }, each level in the order of `names`
local function branch_tree(names)
  local root = { children = {}, folders = {} }
  for _, name in ipairs(names) do
    local node = root
    local parts = vim.split(name, "/", { plain = true })
    for i = 1, #parts - 1 do
      local key = parts[i] .. "/"
      if not node.folders[key] then
        node.folders[key] = { name = key, children = {}, folders = {} }
        table.insert(node.children, node.folders[key])
      end
      node = node.folders[key]
    end
    table.insert(node.children, { name = parts[#parts], branch = name })
  end
  return root
end

local function render(bufnr)
  local state = buffers[bufnr]
  local lines = {}
  local function add(node, level)
    for _, child in ipairs(node.children) do
      table.insert(lines, guides.prefix(level) .. child.name)
      if child.branch then
        for _, policy in ipairs(state.policies[child.branch] or {}) do
          table.insert(lines, guides.prefix(level + 1) .. line_text(state, policy))
        end
      else
        add(child, level + 1)
      end
    end
  end
  add(branch_tree(state.branches), 0)
  local snapshot = fold.snapshot(bufnr)
  repo_screen.set_section(bufnr, SECTION, lines)
  state.loaded = true
  repo_screen.update_modified(bufnr)
  repo_screen.decorate(bufnr)
  fold.collapse(bufnr, snapshot)
end

-- Parsing and changes ---------------------------------------------------------

-- Branches of the section's `lines` (line i being buffer line offset + i): { { name, lnum,
-- lines = { { kind, value, lnum, spec } } } }, plus errors and the folder lines ({ { name, lnum } })
local function parse(state, lines, offset)
  local branches, errors, folders = {}, {}, {}
  local branch
  -- [level] = path of the folder line at that level ("features/new/")
  local paths = {}
  for i, line in ipairs(lines) do
    local lnum = (offset or 0) + i
    if not line:match("^%s*$") then
      local level, rest = parse_indent(line)
      rest = vim.trim(rest)
      -- Right under a branch, a line without ":" is a policy still being typed
      local typing = level > 0 and not paths[level - 1] and branch and level == branch.level + 1
      if not rest:find(":", 1, true) and not typing then
        -- A folder or a branch, under the folder of the level above
        local prefix = level > 0 and paths[level - 1] or ""
        if level > 0 and not paths[level - 1] then
          table.insert(errors, ("Line %d: indented branch without a folder above"):format(lnum))
        end
        for l in pairs(paths) do
          if l >= level then
            paths[l] = nil
          end
        end
        if rest:match("/$") then
          paths[level] = prefix .. rest
          table.insert(folders, { name = paths[level], lnum = lnum })
          branch = nil
        else
          branch = { name = short(prefix .. rest), lnum = lnum, level = level, lines = {} }
          table.insert(branches, branch)
        end
      elseif not branch or level ~= branch.level + 1 then
        table.insert(errors, ("Line %d: policy without a branch right above"):format(lnum))
      else
        local key, value = rest:match("^([^:]+):%s*(.-)$")
        local kind = key and KIND_OF_KEY[vim.trim(key):lower()]
        if not kind then
          table.insert(errors, ("Line %d: not a policy line (%s)"):format(lnum, table.concat(vim.tbl_map(function(k)
            return k.key
          end, KEYS), ", ")))
        else
          local spec, err = parse_value(state, kind, value)
          if not spec then
            table.insert(errors, ("Line %d: %s"):format(lnum, err))
          end
          table.insert(branch.lines, { kind = kind, value = value, lnum = lnum, spec = spec })
        end
      end
    end
  end
  return branches, errors, folders
end

-- Changes of the buffer: { creates = { { branch, policy } }, updates = { { branch, policy, from } },
-- deletes = { { branch, policy } } }, plus a list of errors
local function detect(bufnr)
  local state = buffers[bufnr]
  local lines, offset, present = section(bufnr)
  local branches, errors = parse(state, lines, offset)
  if not present then
    table.insert(errors, repo_screen.missing_header(SECTION))
  end
  local changes = { creates = {}, updates = {}, deletes = {} }
  local by_branch, seen = {}, {}
  for _, b in ipairs(branches) do
    if seen[b.name] then
      table.insert(errors, ("Line %d: branch %s appears twice"):format(b.lnum, b.name))
    end
    seen[b.name] = true
    by_branch[b.name] = b
  end
  -- Every branch with policies or lines
  local names = {}
  for name in pairs(state.policies) do
    names[name] = true
  end
  for name in pairs(by_branch) do
    names[name] = true
  end
  for name in pairs(names) do
    local originals = state.policies[name] or {}
    local lines = by_branch[name] and by_branch[name].lines or {}
    local matched = {}
    local singles = {}
    for _, line in ipairs(lines) do
      if KEY_OF[line.kind].single then
        if singles[line.kind] then
          table.insert(errors, ("Line %d: %s appears twice under %s"):format(line.lnum, KEY_OF[line.kind].key, name))
        end
        singles[line.kind] = line
      end
    end
    local function compare(spec, original)
      local policy = policy_of(state, spec, name, original)
      if not original then
        if spec.enabled or not KEY_OF[spec.kind].single then
          table.insert(changes.creates, { branch = name, policy = policy })
        end
      elseif value_text(state, policy) ~= value_text(state, original) then
        table.insert(changes.updates, { branch = name, policy = policy, from = original })
      end
    end
    -- One per branch: a missing line is off
    for _, entry in ipairs(KEYS) do
      if entry.single then
        local original
        for _, p in ipairs(originals) do
          if p.kind == entry.kind then
            original = original or p
          end
        end
        local line = singles[entry.kind]
        local spec = line and line.spec or (not line and { kind = entry.kind, enabled = false, blocking = true, fields = {} })
        if spec then
          if original then
            matched[original] = true
          end
          compare(spec, original)
        end
      end
    end
    -- Builds and reviewers: matched by pipeline / reviewers, the rest created or deleted
    for _, line in ipairs(lines) do
      if not KEY_OF[line.kind].single and line.spec then
        local original
        for _, p in ipairs(originals) do
          if not matched[p] and p.kind == line.kind and parse_value(state, p.kind, value_text(state, p)) then
            local p_spec = parse_value(state, p.kind, value_text(state, p))
            if p_spec.key == line.spec.key then
              original = p
              break
            end
          end
        end
        if original then
          matched[original] = true
        end
        compare(line.spec, original)
      end
    end
    for _, p in ipairs(originals) do
      if not matched[p] and not KEY_OF[p.kind].single then
        table.insert(changes.deletes, { branch = name, policy = p })
      end
    end
  end
  return changes, errors
end

local function count(changes)
  return #changes.creates + #changes.updates + #changes.deletes
end

-- Decoration ------------------------------------------------------------------

function M.decorate(bufnr)
  local state = buffers[bufnr]
  if not state or not state.loaded then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local branches, _, folders = parse(state, section(bufnr))
  local function mark(lnum, opts)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, 0, opts)
  end
  local function name_hl(lnum, hl)
    local l = lines[lnum]
    mark(lnum, { col = #l:match("^%s*"), end_col = #l, hl_group = hl })
  end
  for _, folder in ipairs(folders) do
    name_hl(folder.lnum, "WorkhorsePolicyFolder")
    local n = 0
    for _, b in ipairs(branches) do
      if b.name:sub(1, #folder.name) == folder.name then
        n = n + 1
      end
    end
    mark(folder.lnum, { virt_text = { { ("  %d branch%s"):format(n, n == 1 and "" or "es"), "WorkhorseBuildMeta" } } })
  end
  for _, b in ipairs(branches) do
    name_hl(b.lnum, "WorkhorseBuildBranch")
    local virt = {}
    if b.name == short(state.repo.default_branch) then
      table.insert(virt, { "  default", "WorkhorseBuildMeta" })
    end
    if not state.on_server[b.name] then
      table.insert(virt, { "  not on the server yet", "WorkhorseRunHint" })
    end
    local status = state.status[b.name] or {}
    local virt_lines = {}
    for _, p in ipairs(status) do
      local name = setting(p, "statusName") or "?"
      local genre = setting(p, "statusGenre")
      table.insert(virt_lines, { { guides.prefix(1) .. "Status check: " .. (genre and (genre .. "/") or "") .. name
        .. ", " .. requirement(p.blocking) .. (p.enabled and "" or ", off") .. "  (read-only)", "WorkhorsePolicyReadonly" } })
    end
    mark(b.lnum, { virt_text = virt, virt_lines = #virt_lines > 0 and virt_lines or nil })

    local originals = state.policies[b.name] or {}
    for _, line in ipairs(b.lines) do
      local l = lines[line.lnum]
      local colon = l:find(":", 1, true)
      local indent = #l:match("^%s*")
      mark(line.lnum, { col = indent, end_col = colon, hl_group = "WorkhorseRunKey" })
      if not line.spec then
        mark(line.lnum, { col = colon, end_col = #l, hl_group = "DiagnosticError" })
      else
        local off = not line.spec.enabled
        mark(line.lnum, { col = colon, end_col = #l, hl_group = off and "Comment"
          or (line.spec.blocking and "WorkhorseRepoAllow" or "WorkhorseRepoInherited") })
        -- What it was (or [new])
        local original
        for _, p in ipairs(originals) do
          if p.kind == line.kind then
            if KEY_OF[p.kind].single then
              original = p
            else
              local p_spec = parse_value(state, p.kind, value_text(state, p))
              if p_spec and p_spec.key == line.spec.key then
                original = p
              end
            end
          end
        end
        if not original then
          if line.spec.enabled or not KEY_OF[line.kind].single then
            mark(line.lnum, { virt_text = { { "  [new]", "DiagnosticOk" } } })
          end
        else
          local before = value_text(state, original)
          if value_text(state, policy_of(state, line.spec, b.name, original)) ~= before then
            mark(line.lnum, { virt_text = { { "  [was " .. before .. "]", "DiagnosticWarn" } } })
          end
        end
      end
    end
  end
end

-- Loading ---------------------------------------------------------------------

local function load(bufnr)
  local state = buffers[bufnr]
  state.loading = true
  local branches, by_branch, failed
  local pending = 4
  local function joined()
    pending = pending - 1
    if pending > 0 then
      return
    end
    if failed then
      state.loading = false
      notify("Failed to load the policies of " .. state.repo.name .. ": " .. failed, vim.log.levels.ERROR)
      return
    end
    state.policies, state.status, state.on_server = {}, {}, {}
    local unknown_ids = {}
    for branch, list in pairs(by_branch) do
      for _, p in ipairs(list) do
        if p.kind == "status" then
          state.status[branch] = state.status[branch] or {}
          table.insert(state.status[branch], p)
        else
          state.policies[branch] = state.policies[branch] or {}
          table.insert(state.policies[branch], p)
          for _, id in ipairs(p.kind == "reviewers" and setting(p, "requiredReviewerIds") or {}) do
            if not identities.by_id(id) then
              table.insert(unknown_ids, id)
            end
          end
        end
      end
      if state.policies[branch] then
        sorted_policies(state.policies[branch])
      end
    end
    for _, b in ipairs(branches) do
      state.on_server[b] = true
    end
    -- Default branch, branches with policies, then the others
    local default = short(state.repo.default_branch)
    local order, added = {}, {}
    local function add(name)
      if name ~= "" and not added[name] then
        added[name] = true
        table.insert(order, name)
      end
    end
    add(default ~= "" and default or "main")
    local with_policies = vim.tbl_keys(state.policies)
    table.sort(with_policies, function(a, b)
      return a:lower() < b:lower()
    end)
    for _, name in ipairs(with_policies) do
      add(name)
    end
    for _, name in ipairs(branches) do
      add(name)
    end
    state.branches = order
    local function done()
      if not buffers[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      state.loading = false
      render(bufnr)
    end
    if #unknown_ids == 0 then
      return done()
    end
    identities_api.by_ids(unknown_ids, function(found)
      identities.remember(found or {})
      done()
    end)
  end
  repos_api.branches(state.repo.id, function(result, err)
    branches = result or {}
    if not result then
      -- An empty repository has no refs to list
      notify("Could not list the branches of " .. state.repo.name .. ": " .. tostring(err), vim.log.levels.WARN)
    end
    joined()
  end)
  policies_api.list(state.repo.id, function(result, err)
    by_branch = result
    if not result then
      failed = failed or tostring(err)
    end
    joined()
  end)
  identities.get(function(_, err)
    if err then
      notify("Could not load the identity cache: " .. err, vim.log.levels.WARN)
    end
    joined()
  end)
  require("workhorse.repos").get(function(cache)
    state.definitions = cache and cache.definitions or {}
    joined()
  end)
end

-- Saving ----------------------------------------------------------------------

local function describe(state, entry, verb)
  return ("%s: %s %s"):format(entry.branch, verb, line_text(state, entry.policy))
end

--- The changes of the section to save: { entries = { { text, hl } } to confirm, apply(callback) }
--- (nil when there are none), or nil and an error
function M.prepare(bufnr)
  local state = buffers[bufnr]
  if not state or (not state.loaded and not state.loading) then
    return nil
  end
  if state.loading then
    return nil, "The policies are still loading"
  end
  if state.saving then
    return nil, "Already saving the policies"
  end
  local changes, errors = detect(bufnr)
  if #errors > 0 then
    return nil, table.concat(errors, "\n")
  end
  if count(changes) == 0 then
    return nil
  end
  local entries = {}
  for _, c in ipairs(changes.creates) do
    table.insert(entries, { text = describe(state, c, "add"), hl = "DiagnosticOk" })
  end
  for _, u in ipairs(changes.updates) do
    table.insert(entries, { text = describe(state, u, "set") .. "  (was " .. value_text(state, u.from) .. ")",
      hl = "DiagnosticWarn" })
  end
  for _, d in ipairs(changes.deletes) do
    table.insert(entries, { text = describe(state, d, "delete"), hl = "DiagnosticError" })
  end
  local function apply(callback)
    state.saving = true
    local steps, failures, applied = {}, {}, 0
    local function step(entry, verb, fn)
      table.insert(steps, function(next_step)
        fn(function(ok, err)
          if ok then
            applied = applied + 1
          else
            table.insert(failures, describe(state, entry, verb) .. ": " .. tostring(err))
          end
          next_step()
        end)
      end)
    end
    for _, d in ipairs(changes.deletes) do
      step(d, "delete", function(cb)
        policies_api.delete(d.policy.id, cb)
      end)
    end
    for _, u in ipairs(changes.updates) do
      step(u, "set", function(cb)
        policies_api.update(u.policy, cb)
      end)
    end
    for _, c in ipairs(changes.creates) do
      step(c, "add", function(cb)
        policies_api.create(c.policy, cb)
      end)
    end
    local function run(index)
      if steps[index] then
        return steps[index](function()
          run(index + 1)
        end)
      end
      state.saving = false
      if #failures > 0 then
        notify("Failed to apply:\n" .. table.concat(failures, "\n"), vim.log.levels.ERROR)
      end
      notify(("Applied %d policy change%s to %s"):format(applied, applied == 1 and "" or "s", state.repo.name))
      if vim.api.nvim_buf_is_valid(bufnr) then
        load(bufnr)
      end
      callback()
    end
    run(1)
  end
  return { entries = entries, apply = apply }
end

-- Buffer ----------------------------------------------------------------------

--- Whether the section has changes (or errors) to save
function M.pending(bufnr)
  local state = buffers[bufnr]
  if not state or not state.loaded or state.loading then
    return false
  end
  local changes, errors = detect(bufnr)
  return count(changes) > 0 or #errors > 0
end

function M.saving(bufnr)
  return buffers[bufnr] ~= nil and buffers[bufnr].saving == true
end

--- Load the policies again, replacing the section
function M.reload(bufnr)
  load(bufnr)
end

local OPTIONS = {
  min_reviewers = { "off", "1", "2", "3", "required", "optional", "creator vote counts", "allow downvotes", "reset on push" },
  work_items = { "required", "optional", "off" },
  comments = { "required", "optional", "off" },
  merge_strategy = { "off", "squash", "no fast-forward", "rebase", "rebase merge" },
  build = { "required", "optional", "automatic", "manual", "expires 720", "never expires", "off" },
  reviewers = { "required", "optional", "off" },
}

-- The folder path a branch typed on line `lnum` goes under ("" at the top level), nil when the
-- line is under a branch (a policy line)
local function folder_of(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local level = parse_indent(line)
  if level == 0 then
    return ""
  end
  local lines, offset = section(bufnr)
  -- The closest line above, less indented
  for l = lnum - 1, offset + 1, -1 do
    local above = lines[l - offset]
    if not above:match("^%s*$") and parse_indent(above) < level then
      local _, _, folders = parse(buffers[bufnr], { unpack(lines, 1, l - offset) }, offset)
      for _, folder in ipairs(folders) do
        if folder.lnum == l then
          return folder.name
        end
      end
      return nil
    end
  end
  return ""
end

-- Completion: branches on the lines naming one (those of its folder, without the folder's path),
-- the policy keys on a line under a branch still without its ":", then each policy's values
-- (pipelines and users or groups first on Build and Reviewer)
function M.choices(bufnr, lnum)
  local state = buffers[bufnr]
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local key = line:match("^%s*([^:]+):")
  local folder = not key and folder_of(bufnr, lnum)
  if folder then
    local names = {}
    for _, name in ipairs(state.branches or {}) do
      if name:sub(1, #folder) == folder then
        table.insert(names, name:sub(#folder + 1))
      end
    end
    return names
  end
  if not key then
    return vim.tbl_map(function(k)
      return k.key .. ": "
    end, KEYS)
  end
  local kind = KIND_OF_KEY[vim.trim(key):lower()]
  if not kind then
    return nil
  end
  -- The first item of a Build or Reviewer line is the pipeline or user/group
  local cursor = vim.api.nvim_win_get_cursor(0)
  local first = true
  if cursor[1] == lnum then
    local colon = line:find(":", 1, true)
    first = not line:sub(colon + 1, cursor[2]):find(",", 1, true)
  end
  if first and kind == "build" then
    return definition_names(state), true
  elseif first and kind == "reviewers" then
    return identities.names(), true
  end
  return OPTIONS[kind], true
end

function M.start(line)
  if not line:find(":", 1, true) then
    return #line:match("^%s*")
  end
end

--- Summary of a fold (lines first..last hidden): the policies of a branch (a folder line shows
--- its number of branches already)
function M.summary(bufnr, first, last)
  local head = vim.api.nvim_buf_get_lines(bufnr, first - 2, first - 1, false)[1] or ""
  if head:match("/%s*$") then
    return ""
  end
  local n = math.max(0, last - first + 1)
  return ("%d polic%s"):format(n, n == 1 and "y" or "ies")
end

--- Set up the Policies section of the repository screen `bufnr` (loaded by M.reload)
function M.attach(bufnr, repo)
  buffers[bufnr] = { repo = repo, branches = {}, on_server = {}, policies = {}, status = {} }
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      buffers[bufnr] = nil
    end,
  })
end

return M
