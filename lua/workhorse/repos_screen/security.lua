-- Security section of the repository screen (repos_screen/repo.lua): who can do what on it, as editable text. Like the web UI it lists
-- every user and group with permissions on the repository, set on it or inherited (from the
-- project's permissions or a group they belong to), groups first:
--
--   Inheritance: on
--   [Project]\Contributors
--     Contribute: Allow (inherited)
--     Read: Allow
--
-- A value is "Not set", "Allow" or "Deny" (set on this repository) or "Allow (inherited)" /
-- "Deny (inherited)" (not set here, which is what writing "Not set" over an inherited value
-- means). A new line at the top level adds a user or group (completed from the identity cache,
-- see workhorse/identities.lua, or picked with <leader>wa): its current permissions are fetched
-- and listed under it. Deleting an identity's block removes the permissions set here for it.
-- Saving (of the whole screen) shows the changes, then applies them.
local M = {}

local repo_screen = require("workhorse.repos_screen.repo")
local security_api = require("workhorse.api.security")
local identities_api = require("workhorse.api.identities")
local identities = require("workhorse.identities")
local parse_indent = require("workhorse.buffer_tree.parser").parse_indent
local guides = require("workhorse.buffer_tree.guides")
local fold = require("workhorse.fold")

local band, bor, bnot = bit.band, bit.bor, bit.bnot

local ns = vim.api.nvim_create_namespace("workhorse_repo_security")

local VALUES = { "Not set", "Allow", "Deny" }
local INHERITANCE = "Inheritance"

-- Per-buffer state: { repo, token, actions = { { bit, name } }, action_by_name, inherit,
-- acl (of the repository, with the extended info), alias = { [descriptor] = descriptor in the
-- ACL, for well-known groups }, baseline = { [descriptor] = ace },
-- listed = { [descriptor] = true } (identities of the last load), fetching = { [descriptor] =
-- true }, loading, loaded, saving }
local buffers = {}

local notify = repo_screen.notify

local SECTION = "security"

-- Lines of the section, the buffer line number before them, and whether the section is there
local function section(bufnr)
  local lines, offset = repo_screen.section_lines(bufnr, SECTION)
  return lines or {}, offset or 0, lines ~= nil
end

-- Values ----------------------------------------------------------------------

-- Display value of `bit` in `ace` ({ allow, deny, effective_allow, effective_deny })
local function value_of(ace, bit_value)
  if band(ace.allow, bit_value) ~= 0 then
    return "Allow"
  elseif band(ace.deny, bit_value) ~= 0 then
    return "Deny"
  elseif band(ace.effective_deny or 0, bit_value) ~= 0 then
    return "Deny (inherited)"
  elseif band(ace.effective_allow or 0, bit_value) ~= 0 then
    return "Allow (inherited)"
  end
  return "Not set"
end

-- Canonical form of a typed value, nil when invalid
local CANONICAL = {
  ["not set"] = "Not set",
  [""] = "Not set",
  allow = "Allow",
  deny = "Deny",
  ["allow (inherited)"] = "Allow (inherited)",
  ["deny (inherited)"] = "Deny (inherited)",
}

local function canonical(value)
  return CANONICAL[vim.trim(value or ""):lower():gsub("%s+", " ")]
end

local EMPTY_ACE = { allow = 0, deny = 0, effective_allow = 0, effective_deny = 0 }

-- Permissions of an identity on the repository (`ace`: its entry of the ACL, nil when it has
-- none) counting those of the groups it belongs to, as the web UI does (the ACL's effective
-- permissions only count the identity's own entries): what is set on the repository for it wins,
-- then a deny from anywhere wins over an allow
local function with_groups(acl, ace, member_of)
  ace = ace or EMPTY_ACE
  local allow, deny = ace.effective_allow, ace.effective_deny
  for _, descriptor in ipairs(member_of or {}) do
    local group = acl.aces[descriptor]
    if group then
      allow = bor(allow, group.effective_allow)
      deny = bor(deny, group.effective_deny)
    end
  end
  deny = band(bor(deny, ace.deny), bnot(ace.allow))
  allow = band(bor(allow, ace.allow), bnot(deny))
  return { allow = ace.allow, deny = ace.deny, effective_allow = allow, effective_deny = deny }
end

-- Rendering -------------------------------------------------------------------

local function identity_of(descriptor)
  return identities.by_descriptor(descriptor) or { descriptor = descriptor, name = descriptor, kind = "user" }
end

local function sort_identities(list)
  table.sort(list, function(a, b)
    if a.kind ~= b.kind then
      return a.kind == "group"
    end
    return a.name:lower() < b.name:lower()
  end)
  return list
end

-- Lines of an identity's block
local function block_lines(state, identity)
  local ace = state.baseline[identity.descriptor] or EMPTY_ACE
  local lines = { identity.name }
  for _, action in ipairs(state.actions) do
    table.insert(lines, guides.prefix(1) .. action.name .. ": " .. value_of(ace, action.bit))
  end
  return lines
end

local function render(bufnr)
  local state = buffers[bufnr]
  local list = {}
  for descriptor in pairs(state.listed) do
    table.insert(list, identity_of(descriptor))
  end
  sort_identities(list)
  local lines = { INHERITANCE .. ": " .. (state.inherit and "on" or "off") }
  for _, identity in ipairs(list) do
    vim.list_extend(lines, block_lines(state, identity))
  end
  local snapshot = fold.snapshot(bufnr)
  repo_screen.set_section(bufnr, SECTION, lines)
  state.loaded = true
  repo_screen.update_modified(bufnr)
  repo_screen.decorate(bufnr)
  fold.collapse(bufnr, snapshot)
end

-- Parsing ---------------------------------------------------------------------

-- Blocks of the section's `lines` (line i being buffer line offset + i): { inherit = { value, lnum } | nil, blocks = { { name, lnum, identity,
-- actions = { [bit] = { value, lnum, raw } } } } }, plus a list of errors
local function parse(state, lines, offset)
  local result, errors = { blocks = {} }, {}
  local block
  for i, line in ipairs(lines) do
    local lnum = (offset or 0) + i
    if not line:match("^%s*$") then
      local level, rest = parse_indent(line)
      rest = vim.trim(rest)
      if level == 0 then
        local setting = rest:match("^" .. INHERITANCE .. "%s*:%s*(.-)$")
        if setting then
          local value = setting:lower()
          if value ~= "on" and value ~= "off" then
            table.insert(errors, ("Line %d: Inheritance is on or off"):format(lnum))
          end
          result.inherit = { value = value == "on", lnum = lnum }
          block = nil
        else
          block = { name = rest, lnum = lnum, identity = identities.by_name(rest), actions = {} }
          table.insert(result.blocks, block)
        end
      else
        local key, value = rest:match("^([^:]+):%s*(.-)$")
        local action = key and state.action_by_name[vim.trim(key):lower()]
        if not block then
          table.insert(errors, ("Line %d: permission without a user or group above"):format(lnum))
        elseif not key then
          table.insert(errors, ("Line %d: not a 'permission: value' line"):format(lnum))
        elseif not action then
          table.insert(errors, ("Line %d: unknown permission %s"):format(lnum, vim.trim(key)))
        elseif not canonical(value) then
          table.insert(errors, ("Line %d: %s is Not set, Allow or Deny"):format(lnum, vim.trim(key)))
        elseif block.actions[action.bit] then
          table.insert(errors, ("Line %d: %s appears twice for %s"):format(lnum, action.name, block.name))
        else
          block.actions[action.bit] = { value = canonical(value), lnum = lnum }
        end
      end
    end
  end
  return result, errors
end

-- Changes of the buffer: { sets = { { identity, allow, deny, diffs = { { action, from, to } } } },
-- removes = { identity }, inherit = bool|nil }, plus a list of errors
local function detect(bufnr)
  local state = buffers[bufnr]
  local lines, offset, present = section(bufnr)
  local parsed, errors = parse(state, lines, offset)
  if not present then
    table.insert(errors, repo_screen.missing_header(SECTION))
  end
  local changes = { sets = {}, removes = {} }
  local seen = {}
  for _, block in ipairs(parsed.blocks) do
    local identity = block.identity
    if not identity then
      table.insert(errors, ("Line %d: unknown user or group %s (<leader>wR updates the identity cache)"):format(
        block.lnum, block.name))
    elseif seen[identity.descriptor] then
      table.insert(errors, ("Line %d: %s appears twice"):format(block.lnum, identity.name))
    else
      seen[identity.descriptor] = true
      local base = state.baseline[identity.descriptor] or EMPTY_ACE
      local allow, deny, diffs = base.allow, base.deny, {}
      for _, action in ipairs(state.actions) do
        local entry = block.actions[action.bit]
        if entry then
          local before = value_of(base, action.bit)
          allow, deny = band(allow, bnot(action.bit)), band(deny, bnot(action.bit))
          if entry.value == "Allow" then
            allow = bor(allow, action.bit)
          elseif entry.value == "Deny" then
            deny = bor(deny, action.bit)
          end
          local explicit_before = before == "Allow" or before == "Deny"
          local explicit_after = entry.value == "Allow" or entry.value == "Deny"
          if explicit_before ~= explicit_after or (explicit_after and before ~= entry.value) then
            table.insert(diffs, { action = action, from = before, to = explicit_after and entry.value or "Not set" })
          end
        end
      end
      if allow ~= base.allow or deny ~= base.deny then
        table.insert(changes.sets, { identity = identity, allow = allow, deny = deny, diffs = diffs })
      end
    end
  end
  for descriptor in pairs(state.listed) do
    local base = state.baseline[descriptor]
    if not seen[descriptor] and base and (base.allow ~= 0 or base.deny ~= 0) then
      table.insert(changes.removes, identity_of(descriptor))
    end
  end
  if parsed.inherit and parsed.inherit.value ~= state.inherit then
    changes.inherit = parsed.inherit.value
  end
  return changes, errors
end

local function count(changes)
  return #changes.sets + #changes.removes + (changes.inherit ~= nil and 1 or 0)
end

-- Decoration ------------------------------------------------------------------

local VALUE_HL = {
  ["Allow"] = "WorkhorseRepoAllow",
  ["Deny"] = "WorkhorseRepoDeny",
  ["Allow (inherited)"] = "WorkhorseRepoInherited",
  ["Deny (inherited)"] = "WorkhorseRepoInherited",
  ["Not set"] = "Comment",
}

function M.decorate(bufnr)
  local state = buffers[bufnr]
  if not state or not state.loaded then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local parsed = parse(state, section(bufnr))
  local function mark(lnum, opts)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, 0, opts)
  end
  if parsed.inherit then
    local indent = #lines[parsed.inherit.lnum]:match("^%s*")
    mark(parsed.inherit.lnum, { col = indent, end_col = indent + #INHERITANCE + 1, hl_group = "WorkhorseRunKey" })
    if parsed.inherit.value ~= state.inherit then
      mark(parsed.inherit.lnum, { virt_text = { { "  [was " .. (state.inherit and "on" or "off") .. "]", "DiagnosticWarn" } } })
    else
      mark(parsed.inherit.lnum, { virt_text = { { "  permissions of the project apply here too", "WorkhorseRunHint" } } })
    end
  end
  for _, block in ipairs(parsed.blocks) do
    local identity = block.identity
    mark(block.lnum, { col = #lines[block.lnum]:match("^%s*"), end_col = #lines[block.lnum], hl_group = "WorkhorseBuildTitle" })
    local virt
    if not identity then
      virt = { { "  unknown user or group", "DiagnosticError" } }
    else
      virt = { { "  " .. identity.kind, "WorkhorseBuildMeta" } }
      if state.fetching[identity.descriptor] then
        table.insert(virt, { "  loading permissions...", "WorkhorseRunHint" })
      elseif not state.listed[identity.descriptor] then
        table.insert(virt, { "  [new]", "DiagnosticOk" })
      end
    end
    mark(block.lnum, { virt_text = virt })
    local base = identity and state.baseline[identity.descriptor] or EMPTY_ACE
    for bit_value, entry in pairs(block.actions) do
      local l = lines[entry.lnum]
      local colon = l:find(":", 1, true)
      local indent = #l:match("^%s*")
      mark(entry.lnum, { col = indent, end_col = colon, hl_group = "WorkhorseRunKey" })
      mark(entry.lnum, { col = colon, end_col = #l, hl_group = VALUE_HL[entry.value] })
      local before = value_of(base, bit_value)
      local explicit = entry.value == "Allow" or entry.value == "Deny"
      if (explicit and before ~= entry.value) or (not explicit and (before == "Allow" or before == "Deny")) then
        mark(entry.lnum, { virt_text = { { "  [was " .. before .. "]", "DiagnosticWarn" } } })
      end
    end
  end
end

-- Loading ---------------------------------------------------------------------

-- Fetch the actions, the repository's ACL and the identities in it, then render
local function load(bufnr)
  local state = buffers[bufnr]
  state.loading = true
  state.alias = {}
  local pending, failed = 3, nil
  local function joined()
    pending = pending - 1
    if pending > 0 then
      return
    end
    if failed then
      state.loading = false
      notify("Failed to load the permissions of " .. state.repo.name .. ": " .. failed, vim.log.levels.ERROR)
      return
    end
    -- Names of the identities the cache does not know (e.g. created since it was updated)
    local unknown = {}
    for descriptor in pairs(state.acl.aces) do
      if not identities.by_descriptor(descriptor) then
        table.insert(unknown, descriptor)
      end
    end
    local function done()
      local descriptors = vim.tbl_keys(state.acl.aces)
      identities_api.memberships(descriptors, function(memberships, err)
        if not buffers[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        if not memberships then
          notify("Could not read the group memberships (permissions from groups not shown): " .. tostring(err),
            vim.log.levels.WARN)
        end
        state.loading = false
        state.inherit = state.acl.inherit
        state.baseline, state.listed, state.fetching = {}, {}, {}
        for descriptor, ace in pairs(state.acl.aces) do
          state.baseline[descriptor] = with_groups(state.acl, ace, (memberships or {})[descriptor])
          state.listed[descriptor] = true
        end
        render(bufnr)
      end)
    end
    if #unknown == 0 then
      return done()
    end
    identities_api.by_descriptors(unknown, function(found)
      identities.remember(found or {})
      for _, identity in ipairs(found or {}) do
        -- An alias of a well-known group: listed (and its permissions read) as the group itself
        local alias = identity.requested
        if alias and alias ~= identity.descriptor and state.acl.aces[alias] then
          state.acl.aces[identity.descriptor] = state.acl.aces[alias]
          state.acl.aces[alias] = nil
          state.alias[identity.descriptor] = alias
        end
      end
      -- Those the server could not name either are listed by descriptor
      for _, descriptor in ipairs(unknown) do
        if state.acl.aces[descriptor] and not identities.by_descriptor(descriptor) then
          identities.remember({ { descriptor = descriptor, name = descriptor, kind = "user" } })
        end
      end
      done()
    end)
  end
  security_api.actions(function(actions, err)
    if actions then
      state.actions, state.action_by_name = actions, {}
      for _, action in ipairs(actions) do
        state.action_by_name[action.name:lower()] = action
      end
    else
      failed = failed or tostring(err)
    end
    joined()
  end)
  security_api.acl(state.token, nil, function(acl, err)
    if not acl then
      failed = failed or tostring(err)
      return joined()
    end
    -- The project's permissions apply to every repository: those of identities without an entry
    -- on this one (e.g. a repository just created, which has none) are listed as inherited
    security_api.acl(security_api.token(state.project_id), nil, function(project_acl)
      for descriptor, ace in pairs(project_acl and project_acl.aces or {}) do
        if not acl.aces[descriptor] and acl.inherit then
          acl.aces[descriptor] = { allow = 0, deny = 0, inherited_allow = ace.effective_allow,
            inherited_deny = ace.effective_deny, effective_allow = ace.effective_allow,
            effective_deny = ace.effective_deny }
        end
      end
      state.acl = acl
      joined()
    end)
  end)
  identities.get(function(_, err)
    if err then
      notify("Could not load the identity cache: " .. err, vim.log.levels.WARN)
    end
    joined()
  end)
end

-- List the permissions of the identities added without them (a line naming a user or group with
-- no permission lines under it): fetched, then inserted under their line
local function expand_new(bufnr)
  local state = buffers[bufnr]
  if not state or not state.loaded or state.loading then
    return
  end
  local parsed = parse(state, section(bufnr))
  for _, block in ipairs(parsed.blocks) do
    local identity = block.identity
    if identity and next(block.actions) == nil and not state.fetching[identity.descriptor] then
      local descriptor = identity.descriptor
      state.fetching[descriptor] = true
      local ace, member_of
      local pending = 2
      local function joined()
        pending = pending - 1
        if pending > 0 or not buffers[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        state.fetching[descriptor] = nil
        state.baseline[descriptor] = state.baseline[descriptor] or with_groups(state.acl, ace, member_of)
        -- The line may have moved meanwhile: find it again, still without permissions
        local current = parse(state, section(bufnr)).blocks
        for _, b in ipairs(current) do
          if b.identity and b.identity.descriptor == descriptor and next(b.actions) == nil then
            local block_text = block_lines(state, b.identity)
            table.remove(block_text, 1)
            vim.api.nvim_buf_set_lines(bufnr, b.lnum, b.lnum, false, repo_screen.indent(block_text))
            break
          end
        end
        M.decorate(bufnr)
      end
      security_api.acl(state.token, { descriptor }, function(acl)
        ace = acl and acl.aces[descriptor]
        joined()
      end)
      identities_api.memberships({ descriptor }, function(memberships)
        member_of = memberships and memberships[descriptor]
        joined()
      end)
    end
  end
  M.decorate(bufnr)
end

-- Pick a user or group from the identity cache and add it after the block under the cursor
local function add_identity(bufnr)
  local state = buffers[bufnr]
  if not state.loaded then
    return
  end
  identities.get(function(data, err)
    if not data then
      notify("Could not load the users and groups: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.ui.select(data.identities, {
      prompt = "Add a user or group to " .. state.repo.name,
      format_item = function(i)
        return ("%s  (%s%s)"):format(i.name, i.kind, i.email and (", " .. i.email) or "")
      end,
    }, function(identity)
      if not identity or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      -- After the end of the block under the cursor (or at the end of the section)
      local lines, offset, present = section(bufnr)
      if not present then
        notify(repo_screen.missing_header(SECTION), vim.log.levels.WARN)
        return
      end
      local last = offset + #lines
      while last > offset and lines[last - offset]:match("^%s*$") do
        last = last - 1
      end
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local at = last
      if row > offset and row <= last then
        for lnum = row + 1, last do
          if lines[lnum - offset]:match("^%S") then
            at = lnum - 1
            break
          end
        end
      end
      vim.api.nvim_buf_set_lines(bufnr, at, at, false, repo_screen.indent({ identity.name }))
      vim.api.nvim_win_set_cursor(0, { at + 1, guides.width() })
      expand_new(bufnr)
    end)
  end)
end

-- Saving ----------------------------------------------------------------------

-- Descriptor of an identity in the ACL (its alias for a well-known group)
local function acl_descriptor(state, identity)
  return state.alias[identity.descriptor] or identity.descriptor
end

--- The changes of the section to save: { entries = { { text, hl } } to confirm, apply(callback) }
--- (nil when there are none), or nil and an error
function M.prepare(bufnr)
  local state = buffers[bufnr]
  if not state or (not state.loaded and not state.loading) then
    return nil
  end
  if state.loading then
    return nil, "The permissions are still loading"
  end
  if state.saving then
    return nil, "Already saving the permissions"
  end
  if next(state.fetching) then
    return nil, "Wait for the permissions of the added users and groups to load"
  end
  local changes, errors = detect(bufnr)
  if #errors > 0 then
    return nil, table.concat(errors, "\n")
  end
  if count(changes) == 0 then
    return nil
  end

  local entries = {}
  for _, set in ipairs(changes.sets) do
    table.insert(entries, { text = set.identity.name, hl = "WorkhorseBuildTitle" })
    for _, diff in ipairs(set.diffs) do
      table.insert(entries, { text = ("  %s: %s → %s"):format(diff.action.name, diff.from, diff.to),
        hl = VALUE_HL[diff.to] })
    end
  end
  for _, identity in ipairs(changes.removes) do
    table.insert(entries, { text = identity.name .. ": remove the permissions set on this repository",
      hl = "DiagnosticError" })
  end
  if changes.inherit ~= nil then
    table.insert(entries, { text = "Inheritance: " .. (changes.inherit and "on" or "off"), hl = "DiagnosticWarn" })
  end

  local function apply(callback)
    state.saving = true
    local failures, applied = {}, 0
    local steps = {}
    for _, set in ipairs(changes.sets) do
      table.insert(steps, function(next_step)
        local fn = (set.allow == 0 and set.deny == 0)
          and function(cb)
            security_api.remove_aces(state.token, { acl_descriptor(state, set.identity) }, cb)
          end
          or function(cb)
            security_api.set_ace(state.token, acl_descriptor(state, set.identity), set.allow, set.deny, cb)
          end
        fn(function(ok, err)
          if ok then
            applied = applied + 1
          else
            table.insert(failures, set.identity.name .. ": " .. tostring(err))
          end
          next_step()
        end)
      end)
    end
    if #changes.removes > 0 then
      table.insert(steps, function(next_step)
        local descriptors = vim.tbl_map(function(i)
          return acl_descriptor(state, i)
        end, changes.removes)
        security_api.remove_aces(state.token, descriptors, function(ok, err)
          if ok then
            applied = applied + #descriptors
          else
            table.insert(failures, "removing permissions: " .. tostring(err))
          end
          next_step()
        end)
      end)
    end
    if changes.inherit ~= nil then
      table.insert(steps, function(next_step)
        security_api.set_inheritance(state.token, changes.inherit, function(ok, err)
          if ok then
            applied = applied + 1
          else
            table.insert(failures, "inheritance: " .. tostring(err))
          end
          next_step()
        end)
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
      notify(("Applied %d permission change%s to %s"):format(applied, applied == 1 and "" or "s", state.repo.name))
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

--- Load the permissions again, replacing the section
function M.reload(bufnr)
  load(bufnr)
end

-- Level of a buffer line in the section (its indent taken off)
local function level_of(line)
  return (parse_indent(repo_screen.dedent(line)))
end

-- Completion: the identities on the top-level lines, the values on the permission lines (and
-- the permissions on a permission line still without its ":")
function M.choices(bufnr, lnum)
  local state = buffers[bufnr]
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  if level_of(line) == 0 then
    if line:match("^%s*" .. INHERITANCE .. "%s*:") then
      return { "on", "off" }
    end
    return identities.names()
  end
  if line:find(":", 1, true) then
    return VALUES
  end
  return vim.tbl_map(function(action)
    return action.name .. ": "
  end, state and state.actions or {})
end

function M.start(line)
  local level = level_of(line)
  if (level == 0 and not line:match("^%s*" .. INHERITANCE .. "%s*:")) or (level > 0 and not line:find(":", 1, true)) then
    return #line:match("^%s*")
  end
end

--- Summary of a folded identity block (lines first-1..last)
function M.summary(bufnr, first, last)
  local state = buffers[bufnr]
  if not state or not state.action_by_name then
    return ""
  end
  local parsed = parse(state, vim.tbl_map(repo_screen.dedent, vim.api.nvim_buf_get_lines(bufnr, first - 2, last, false)),
    first - 2)
  local block = parsed.blocks[1]
  if not block then
    return ""
  end
  local read = state.action_by_name["read"]
  local here = 0
  for _, entry in pairs(block.actions) do
    if entry.value == "Allow" or entry.value == "Deny" then
      here = here + 1
    end
  end
  local read_value = read and block.actions[read.bit] and block.actions[read.bit].value or "?"
  return ("Read: %s · %d set here"):format(read_value, here)
end

function M.keymaps(bufnr, map)
  map("<leader>wa", function()
    add_identity(bufnr)
  end, "add a user or group")
end

--- Set up the Security section of the repository screen `bufnr` (loaded by M.reload)
function M.attach(bufnr, repo)
  buffers[bufnr] = {
    repo = repo,
    project_id = repo.project and repo.project.id or "",
    token = security_api.token(repo.project and repo.project.id or "", repo.id),
    actions = {},
    action_by_name = {},
    baseline = {},
    listed = {},
    fetching = {},
    alias = {},
  }
  local group = vim.api.nvim_create_augroup("workhorse_repo_security_" .. bufnr, { clear = true })
  -- A user or group typed (or pasted) without permissions gets them listed
  vim.api.nvim_create_autocmd({ "InsertLeave", "TextChanged" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      expand_new(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      buffers[bufnr] = nil
    end,
  })
end

return M
