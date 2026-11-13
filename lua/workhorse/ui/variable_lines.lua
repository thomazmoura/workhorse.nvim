-- Variables as editable "name: value" lines, shared by the Variables section of a library
-- (libraries_screen/variables.lua) and the Variables tab of a pipeline (pipeline_screen/variables.lua):
--
--   ApiUrl: https://example.com
--   Password (secret):
--   Environment (settable): dev
--   Token (secret, settable):
--
-- The markers in parentheses after a name are the variable's flags; which ones a screen reads is
-- its `flags` list ({ "secret" } for libraries, { "secret", "settable" } for pipelines). A
-- parenthesis holding anything else stays part of the name. A secret's value is never sent by the
-- server: its line shows it empty, which keeps it; typing a value replaces it. Line breaks of a
-- value show as \n.
--
-- A variable is { value (nil for a secret kept as it is), secret, settable, readonly }.
local M = {}

M.FLAG_LABELS = { secret = "secret", settable = "settable" }

function M.escape(value)
  return ((value or ""):gsub("\r?\n", "\\n"))
end

-- " (secret, settable)" for the flags of `var` among `flags`, "" without any
function M.marker(var, flags)
  local set = {}
  for _, flag in ipairs(flags) do
    if var[flag] then
      table.insert(set, flag)
    end
  end
  return #set > 0 and (" (" .. table.concat(set, ", ") .. ")") or ""
end

--- Line of a variable
function M.line_of(name, var, flags)
  return name .. M.marker(var, flags) .. ": " .. (var.secret and "" or M.escape(var.value))
end

function M.sorted_names(variables)
  local names = vim.tbl_keys(variables)
  table.sort(names, function(a, b)
    return a:lower() < b:lower()
  end)
  return names
end

--- Lines of `variables`, sorted by name
function M.render(variables, flags)
  local lines = {}
  for _, name in ipairs(M.sorted_names(variables)) do
    table.insert(lines, M.line_of(name, variables[name], flags))
  end
  return lines
end

-- Name and flags of a key: "Name (secret, settable)" -> "Name", { secret = true, settable = true };
-- a parenthesis holding something else than `flags` stays part of the name
local function split_key(key, flags)
  local base, inside = key:match("^(.-)%s*%(([^()]*)%)$")
  if not base then
    return key, {}
  end
  local allowed, set = {}, {}
  for _, flag in ipairs(flags) do
    allowed[flag] = true
  end
  for word in inside:gmatch("[^,]+") do
    word = vim.trim(word):lower()
    if not allowed[word] then
      return key, {}
    end
    set[word] = true
  end
  return base, set
end

--- Variables of `lines` (line i being buffer line offset + i): { { name, secret, settable, value,
--- lnum } }, plus errors. `settable` is nil when `flags` does not have it
function M.parse(lines, offset, flags)
  local entries, errors = {}, {}
  local has_settable = vim.tbl_contains(flags, "settable")
  for i, line in ipairs(lines) do
    if not line:match("^%s*$") then
      local lnum = offset + i
      local key, value = line:match("^%s*([^:]*):%s*(.-)$")
      if not key then
        table.insert(errors, ("Line %d: not a 'name: value' line"):format(lnum))
      else
        local name, set = split_key(vim.trim(key), flags)
        local settable
        if has_settable then
          settable = set.settable == true
        end
        local entry = {
          name = name,
          secret = set.secret == true,
          settable = settable,
          value = value,
          lnum = lnum,
        }
        if entry.name == "" then
          table.insert(errors, ("Line %d: variable without a name"):format(lnum))
        else
          table.insert(entries, entry)
        end
      end
    end
  end
  return entries, errors
end

--- Name (as stored) of the variable `name`, case aside (variable names are case-insensitive)
function M.original_name(variables, name)
  if variables[name] then
    return name
  end
  for n in pairs(variables) do
    if n:lower() == name:lower() then
      return n
    end
  end
end

local function same_flag(a, b)
  return (a or false) == (b or false)
end

--- What a parsed line means for the variable it names: "same", "added" or "changed", and the
--- variable it sets
function M.compare(variables, entry)
  local name = M.original_name(variables, entry.name)
  local before = name and variables[name]
  if not before then
    return "added", { value = entry.value, secret = entry.secret, settable = entry.settable, readonly = false }
  end
  local settable_same = same_flag(before.settable, entry.settable)
  if before.secret and entry.secret and entry.value == "" then
    if name == entry.name and settable_same then
      return "same", before
    end
    return "changed", { value = before.value, secret = true, settable = entry.settable, readonly = before.readonly }
  end
  local value = entry.value
  if before.value and before.value:find("\n") then
    -- Line breaks of a value shown as \n
    value = (value:gsub("\\n", "\n"))
  end
  if name == entry.name and not before.secret and not entry.secret and value == before.value and settable_same then
    return "same", before
  end
  return "changed", { value = value, secret = entry.secret, settable = entry.settable, readonly = before.readonly }
end

--- Changes of `entries` against the `current` variables: { variables = new map, diffs = { { kind =
--- "added"|"changed"|"removed", name, before, after } } }, plus errors (names given twice)
function M.detect(current, entries)
  local variables, diffs, seen, errors = {}, {}, {}, {}
  for _, entry in ipairs(entries) do
    local key = entry.name:lower()
    if seen[key] then
      table.insert(errors, ("Line %d: %s appears more than once"):format(entry.lnum, entry.name))
    else
      seen[key] = true
      local kind, var = M.compare(current, entry)
      variables[entry.name] = var
      if kind ~= "same" then
        local name = M.original_name(current, entry.name)
        table.insert(diffs, { kind = kind, name = entry.name, before = name and current[name], after = var })
      end
    end
  end
  for _, name in ipairs(M.sorted_names(current)) do
    if not seen[name:lower()] then
      table.insert(diffs, { kind = "removed", name = name, before = current[name] })
    end
  end
  return { variables = variables, diffs = diffs }, errors
end

-- Decoration ------------------------------------------------------------------

function M.shorten(text)
  text = M.escape(text)
  return #text > 40 and (text:sub(1, 37) .. "...") or text
end

-- "secret, settable" for the flags of an added variable
local function flag_words(var, flags)
  local words = {}
  for _, flag in ipairs(flags) do
    if var[flag] then
      table.insert(words, flag)
    end
  end
  return table.concat(words, " ")
end

--- Hint of a changed variable: what it was ("[was ...]")
local function was_text(before, var)
  local parts = {}
  local value_changed = not (before.secret and var.secret and var.value == before.value)
    and not (not before.secret and not var.secret and var.value == before.value)
  if before.secret and var.secret and var.value ~= before.value then
    table.insert(parts, "secret: replaced")
  elseif value_changed then
    table.insert(parts, before.secret and "secret" or M.shorten(before.value))
  end
  if not same_flag(before.settable, var.settable) then
    table.insert(parts, before.settable and "settable" or "not settable")
  end
  if #parts == 0 then
    -- Renamed (case) only
    table.insert(parts, "named differently")
  end
  return table.concat(parts, ", ")
end

--- Highlights and hints of the variable lines of `bufnr` in namespace `ns`. opts:
---   flags     the flags read (see the top of this file)
---   override  fn(entry) -> virt text chunk to show instead of the usual hint, or nil
function M.decorate(bufnr, ns, entries, current, opts)
  local flags = opts.flags
  local function mark(lnum, mark_opts)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, 0, mark_opts)
  end
  local seen = {}
  for _, entry in ipairs(entries) do
    local line = vim.api.nvim_buf_get_lines(bufnr, entry.lnum - 1, entry.lnum, false)[1]
    local indent = #line:match("^%s*")
    local colon = line:find(":", 1, true)
    mark(entry.lnum, { col = indent, end_col = indent + #entry.name, hl_group = "WorkhorseRunKey" })
    if entry.secret or entry.settable then
      local paren = line:find("(", indent + #entry.name + 1, true)
      if paren and paren < colon then
        mark(entry.lnum, { col = paren - 1, end_col = colon - 1, hl_group = "DiagnosticHint" })
      end
    end
    local kind, var = M.compare(current, entry)
    local before = current[M.original_name(current, entry.name) or ""]
    local virt
    if seen[entry.name:lower()] then
      virt = { "  appears more than once", "DiagnosticError" }
    elseif opts.override and opts.override(entry) then
      virt = opts.override(entry)
    elseif kind == "added" then
      local words = flag_words(var, flags)
      virt = { "  [new" .. (words ~= "" and " " .. words or "") .. "]", "DiagnosticOk" }
    elseif kind == "changed" then
      virt = { "  [was " .. was_text(before, var) .. "]", "DiagnosticWarn" }
    elseif var.secret then
      virt = { "  ••••••  type a value to replace it", "WorkhorseRunHint" }
    elseif var.value and var.value:find("\n") then
      virt = { "  line breaks shown as \\n", "WorkhorseRunHint" }
    end
    seen[entry.name:lower()] = true
    if virt then
      mark(entry.lnum, { virt_text = { virt } })
    end
  end
end

-- Saving ----------------------------------------------------------------------

local function value_text(var)
  return var.secret and "••••••" or M.shorten(var.value)
end

--- Entries ({ text, hl }) listing `diffs` in a list_confirm
function M.confirm_entries(diffs, flags)
  local entries = {}
  for _, diff in ipairs(diffs) do
    local marker = diff.after and M.marker(diff.after, flags) or ""
    if diff.kind == "added" then
      table.insert(entries, { text = ("+ %s%s: %s"):format(diff.name, marker, value_text(diff.after)),
        hl = "DiagnosticOk" })
    elseif diff.kind == "removed" then
      table.insert(entries, { text = "- " .. diff.name, hl = "DiagnosticError" })
    else
      local after = diff.after.value == nil and "(kept)" or diff.after.secret and "new secret value"
        or value_text(diff.after)
      table.insert(entries, { text = ("~ %s%s: %s → %s"):format(diff.name, marker, value_text(diff.before), after),
        hl = "DiagnosticWarn" })
    end
  end
  return entries
end

return M
