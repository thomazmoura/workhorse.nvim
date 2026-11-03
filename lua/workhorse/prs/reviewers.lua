-- Reviewers section of the pull request Overview (prs/init.lua), editable as text on an active
-- pull request, like the Security sections of the repository and library screens:
--
--   Reviewers
--     [GTI]\Contributors: optional              ✅ Approved
--     Thomaz Moura: required                    ⏳ No vote
--
-- A new line adds a reviewer (a user or group, completed from the identity cache, see
-- workhorse/identities.lua), its value saying whether they are required (a line without one is
-- optional); deleting a line removes the reviewer; changing the value only changes that flag (the
-- vote stays). The section works on the lines prs/init.lua hands over (the section's own, header
-- left out) and adds the rendered ones to its view.
local M = {}

local render = require("workhorse.builds.render")
local prs_api = require("workhorse.api.pullrequests")
local identities = require("workhorse.identities")

M.HEADER = "Reviewers"

local VALUES = { "required", "optional" }
local INDENT = "  "

-- Name of a reviewer as listed: the identity cache's (what completion inserts) when known
local function display_name(reviewer)
  local identity = identities.by_id(reviewer.id)
  return identity and identity.name or reviewer.name
end

local function baseline(ctx)
  return ctx.data.pr and ctx.data.pr.reviewers or {}
end

-- Reviewers of the pull request by id, and by lowercase name (their name on the pull request and
-- in the cache)
local function index(ctx)
  local by_id, by_name = {}, {}
  for _, r in ipairs(baseline(ctx)) do
    by_id[r.id] = r
    by_name[r.name:lower()] = r
    by_name[display_name(r):lower()] = r
  end
  return by_id, by_name
end

--- Lines of the section for the pull request as it is: required reviewers first, then by name
function M.canonical(ctx)
  local reviewers = vim.list_slice(baseline(ctx))
  table.sort(reviewers, function(a, b)
    if a.required ~= b.required then
      return a.required
    end
    return display_name(a):lower() < display_name(b):lower()
  end)
  return vim.tbl_map(function(r)
    return INDENT .. display_name(r) .. ": " .. (r.required and "required" or "optional")
  end, reviewers)
end

-- A line split into its parts: { indent, name, rest (from the ":" on, "" without one), value
-- (lowercase, "" when missing) }; nil for a blank line
local function split(line)
  if line:match("^%s*$") then
    return nil
  end
  local indent, name, rest = line:match("^(%s*)(.-)(%s*:.*)$")
  if not indent then
    indent, name = line:match("^(%s*)(.-)%s*$")
    rest = line:sub(#indent + #name + 1)
  end
  local value = rest:match("^%s*:%s*(.-)%s*$") or ""
  return { indent = indent, name = name, rest = rest, value = value:lower() }
end

-- Reviewer of a parsed line: { id, name, required, known (the reviewer on the pull request, if
-- one) }, or nil and an error
local function resolve(ctx, parts, by_name)
  if parts.value ~= "" and not vim.tbl_contains(VALUES, parts.value) then
    return nil, "is required or optional"
  end
  local required = parts.value == "required"
  local known = by_name[parts.name:lower()]
  if known then
    return { id = known.id, name = display_name(known), required = required, known = known }
  end
  local identity = identities.by_name(parts.name)
  if not identity or not identity.id then
    return nil, "unknown user or group"
  end
  local by_id = index(ctx)
  return { id = identity.id, name = identity.name, required = required, known = by_id[identity.id] }
end

--- Add the section (its header, then `lines`, the edited ones or M.canonical) to `view`; with
--- `editable`, hints show what saving would change
function M.render(view, ctx, lines, editable)
  local hint = nil
  if editable and #lines == 0 then
    hint = { { "o adds a reviewer", "WorkhorseRunHint" } }
  end
  render.add_line(view, { { M.HEADER, "WorkhorseRunSection" } }, nil, hint)
  if not editable and #lines == 0 then
    render.add_line(view, { { INDENT .. "None", "WorkhorseBuildMeta" } })
    return
  end
  local _, by_name = index(ctx)
  local seen = {}
  for _, line in ipairs(lines) do
    local parts = split(line)
    if not parts then
      render.add_line(view, { { line } })
    else
      local reviewer, err = resolve(ctx, parts, by_name)
      local virt = {}
      local value_hl = parts.value == "required" and "WorkhorseRunRequired" or "WorkhorseBuildMeta"
      if reviewer and reviewer.known then
        local label, icon, hl = prs_api.vote_display(reviewer.known.vote)
        table.insert(virt, { icon .. " " .. label, hl })
        if editable and reviewer.known.required ~= reviewer.required then
          table.insert(virt, { "  [was " .. (reviewer.known.required and "required" or "optional") .. "]",
            "DiagnosticWarn" })
        end
      elseif reviewer and editable then
        table.insert(virt, { "[new]", "DiagnosticOk" })
      end
      if err then
        table.insert(virt, { err, "DiagnosticError" })
      elseif seen[reviewer.id] then
        table.insert(virt, { "listed twice", "DiagnosticError" })
      end
      if reviewer then
        seen[reviewer.id] = true
      end
      render.add_line(view, {
        { parts.indent },
        { parts.name, reviewer and "WorkhorseBuildTitle" or nil },
        { parts.rest, value_hl },
      }, { kind = "edit", section = "reviewers" }, #virt > 0 and virt or nil)
    end
  end
end

-- Changes of `lines`: { adds = { reviewer }, updates = { reviewer }, removes = { reviewer on the
-- pull request } }, plus a list of errors
local function detect(ctx, lines)
  local by_id, by_name = index(ctx)
  local changes, errors, seen = { adds = {}, updates = {}, removes = {} }, {}, {}
  for _, line in ipairs(lines) do
    local parts = split(line)
    if parts then
      local reviewer, err = resolve(ctx, parts, by_name)
      if not reviewer then
        table.insert(errors, ("%s: %s"):format(parts.name, err))
      elseif seen[reviewer.id] then
        table.insert(errors, ("%s is listed twice"):format(reviewer.name))
      else
        seen[reviewer.id] = true
        if not reviewer.known then
          table.insert(changes.adds, reviewer)
        elseif reviewer.known.required ~= reviewer.required then
          table.insert(changes.updates, reviewer)
        end
      end
    end
  end
  for id, r in pairs(by_id) do
    if not seen[id] then
      table.insert(changes.removes, r)
    end
  end
  return changes, errors
end

--- The changes of `lines` to save: { entries = { { text, hl } } to confirm, apply(callback) } (nil
--- when there are none), or nil and an error
function M.prepare(ctx, lines)
  local changes, errors = detect(ctx, lines)
  if #errors > 0 then
    return nil, table.concat(errors, "\n")
  end
  local entries, steps = {}, {}
  local repo, id = ctx.repo, ctx.id
  for _, r in ipairs(changes.adds) do
    table.insert(entries, { text = "  + " .. r.name .. (r.required and " (required)" or ""), hl = "DiagnosticOk" })
    table.insert(steps, { label = r.name, run = function(cb)
      prs_api.add_reviewer(repo, id, r.id, r.required, cb)
    end })
  end
  for _, r in ipairs(changes.updates) do
    table.insert(entries, { text = ("  ~ %s: %s → %s"):format(r.name, r.known.required and "required" or "optional",
      r.required and "required" or "optional"), hl = "DiagnosticWarn" })
    table.insert(steps, { label = r.name, run = function(cb)
      prs_api.add_reviewer(repo, id, r.id, r.required, cb)
    end })
  end
  for _, r in ipairs(changes.removes) do
    table.insert(entries, { text = "  - " .. display_name(r), hl = "DiagnosticError" })
    table.insert(steps, { label = display_name(r), run = function(cb)
      prs_api.remove_reviewer(repo, id, r.id, cb)
    end })
  end
  if #steps == 0 then
    return nil
  end
  return { entries = entries, steps = steps }
end

--- Completion: the identities on a line without ":", the values after it
function M.choices(line)
  if line:find(":", 1, true) then
    return VALUES
  end
  return identities.names()
end

--- Column (0-based) where the completed value of `line` starts
function M.start(line)
  if not line:find(":", 1, true) then
    return #line:match("^%s*")
  end
end

return M
