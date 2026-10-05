-- "Run new build" form: a buffer with the branch, the YAML runtime parameters and
-- the variables settable at queue time of a pipeline, one "name: value" line each.
-- <Tab>/<S-Tab> move between the values, typing in the branch or a field with choices
-- shows them, and <CR>, <leader><leader> (or :w) queues the run after a confirmation.
-- Only values that differ from the pipeline's defaults are sent.
local M = {}

local builds_api = require("workhorse.api.builds")
local yaml = require("workhorse.builds.yaml")
local config = require("workhorse.config")

local ns = vim.api.nvim_create_namespace("workhorse_new_run")

-- Section headers; "Branch:" sits above them
local PARAMETERS = "## Parameters"
local VARIABLES = "## Variables"

-- Per-buffer form state: { definition, params, variables, initial, branches, prev }
local forms = {}

local counter = 0

-- Text shown for a parameter value: defaults of object parameters become one-line JSON,
-- newlines in strings are shown as \n
local function display_value(value)
  if value == nil or value == vim.NIL then
    return ""
  elseif type(value) == "table" then
    return yaml.encode(value)
  end
  return (tostring(value):gsub("\n", "\\n"))
end

local function short_branch(ref)
  return (ref or ""):gsub("^refs/heads/", "")
end

-- Lines of the form, with the values of `values` ({ branch, params = {}, variables = {} })
-- winning over the defaults
local function build_lines(form, values)
  values = values or { params = {}, variables = {} }
  local lines = {
    "# Run new build: " .. form.definition.name,
    "Branch: " .. (values.branch or short_branch(form.definition.repository.default_branch)),
  }
  if form.params_error then
    vim.list_extend(lines, { "", PARAMETERS, "# Could not read the runtime parameters: " .. form.params_error })
  elseif #form.params > 0 then
    vim.list_extend(lines, { "", PARAMETERS })
    for _, p in ipairs(form.params) do
      table.insert(lines, p.name .. ": " .. (values.params[p.name] or display_value(p.default)))
    end
  end
  if #form.definition.variables > 0 then
    vim.list_extend(lines, { "", VARIABLES })
    for _, v in ipairs(form.definition.variables) do
      table.insert(lines, v.name .. ": " .. (values.variables[v.name] or v.value))
    end
  end
  table.insert(lines, "")
  return lines
end

--- Parse the form lines into { branch, params = { [name] = value }, variables = {...},
--- lnums = { [section .. name] = lnum }, unknown = { "line" } }
function M.parse_lines(lines)
  local result = { params = {}, variables = {}, lnums = {}, unknown = {} }
  local section
  for lnum, line in ipairs(lines) do
    if line == PARAMETERS then
      section = "params"
    elseif line == VARIABLES then
      section = "variables"
    elseif not line:match("^%s*$") and not line:match("^#") then
      local key, value = line:match("^([^:]+):%s?(.*)$")
      key = key and vim.trim(key)
      value = value and vim.trim(value)
      if not key then
        table.insert(result.unknown, line)
      elseif not section and key:lower() == "branch" then
        result.branch = value
        result.lnums.branch = lnum
      elseif section then
        result[section][key] = value
        result.lnums[section .. ":" .. key] = lnum
      else
        table.insert(result.unknown, line)
      end
    end
  end
  return result
end

local function param_by_name(form, name)
  for _, p in ipairs(form.params) do
    if p.name == name then
      return p
    end
  end
end

local function variable_by_name(form, name)
  for _, v in ipairs(form.definition.variables) do
    if v.name == name then
      return v
    end
  end
end

-- Right-hand hint of a parameter: its type, allowed values and whether it is required
local function param_hint(p)
  local parts = { p.type }
  if p.values then
    local shown = {}
    for _, v in ipairs(p.values) do
      table.insert(shown, display_value(v))
    end
    table.insert(parts, table.concat(shown, " | "))
  end
  local chunks = { { "  " .. table.concat(parts, " · "), "WorkhorseRunHint" } }
  if p.default == nil then
    table.insert(chunks, { "  required", "WorkhorseRunRequired" })
  end
  return chunks
end

-- Highlights and hints, recomputed on every change so they follow the lines
local function decorate(bufnr)
  local form = forms[bufnr]
  if not form then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local section
  for lnum, line in ipairs(lines) do
    local row = lnum - 1
    if lnum == 1 and line:match("^# ") then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { end_col = #line, hl_group = "WorkhorseBuildHeader" })
    elseif line == PARAMETERS or line == VARIABLES then
      section = line
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { end_col = #line, hl_group = "WorkhorseRunSection" })
    elseif line:match("^#") then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { end_col = #line, hl_group = "WorkhorseRunHint" })
    else
      local key = line:match("^([^:#][^:]*):")
      if key then
        vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { end_col = #key + 1, hl_group = "WorkhorseRunKey" })
        local name = vim.trim(key)
        local p = section == PARAMETERS and param_by_name(form, name)
        local v = section == VARIABLES and variable_by_name(form, name)
        if p then
          local mark = { virt_text = param_hint(p) }
          if p.display_name and p.display_name ~= p.name then
            mark.virt_lines = { { { p.display_name, "WorkhorseRunHint" } } }
            mark.virt_lines_above = true
          end
          vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, mark)
        elseif v and v.secret then
          vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { virt_text = { { "  secret", "WorkhorseRunHint" } } })
        elseif not section and name:lower() == "branch" and form.definition.repository.name then
          vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
            virt_text = { { "  " .. form.definition.repository.name, "WorkhorseRunHint" } },
          })
        end
      end
    end
  end
end

-- Completion ------------------------------------------------------------------

-- Candidates for the field on line `lnum`: branches, or a parameter's allowed values
local function candidates(bufnr, lnum)
  local form = forms[bufnr]
  local parsed = M.parse_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  if parsed.lnums.branch == lnum then
    return form.branches or {}
  end
  for name in pairs(parsed.params) do
    if parsed.lnums["params:" .. name] == lnum then
      local p = param_by_name(form, name)
      if p and p.values then
        return vim.tbl_map(display_value, p.values)
      elseif p and p.type == "boolean" then
        return { "true", "false" }
      end
    end
  end
  return {}
end

--- omnifunc of the form (<C-x><C-o> on the branch and on parameter lines)
function M.omnifunc(findstart, base)
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  if findstart == 1 then
    local colon = line:find(":")
    if not colon or not forms[bufnr] then
      return -3
    end
    return colon + #(line:sub(colon + 1):match("^%s*"))
  end
  -- Values starting with the text, then containing it, then fuzzy matches (best first, e.g.
  -- "fealog" for "feature/login-page")
  local prefix, rest, seen = {}, {}, {}
  local query = base:lower()
  local words = candidates(bufnr, lnum)
  for _, word in ipairs(words) do
    local lower = word:lower()
    if lower:find(query, 1, true) == 1 then
      table.insert(prefix, word)
      seen[word] = true
    elseif lower:find(query, 1, true) then
      table.insert(rest, word)
      seen[word] = true
    end
  end
  vim.list_extend(prefix, rest)
  if query ~= "" then
    for _, word in ipairs(vim.fn.matchfuzzy(words, base)) do
      if not seen[word] then
        table.insert(prefix, word)
      end
    end
  end
  return prefix
end

-- Whether line `lnum` is the branch (once the repository's branches are loaded) or a
-- parameter with allowed values (or a boolean)
local function has_choices(bufnr, lnum)
  local parsed = M.parse_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  if parsed.lnums.branch == lnum then
    return forms[bufnr].branches ~= nil
  end
  for name in pairs(parsed.params) do
    if parsed.lnums["params:" .. name] == lnum then
      local p = param_by_name(forms[bufnr], name)
      return p ~= nil and (p.values ~= nil or p.type == "boolean")
    end
  end
  return false
end

--- Choices matching the value typed before the cursor of the current window, for a field
--- with choices: { start = 0-based column of the value, base = typed text, matches = {...} }
--- or nil (another buffer, a free-text field, the cursor before the value)
function M.choice_completion()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  if not forms[bufnr] or not has_choices(bufnr, cursor[1]) then
    return nil
  end
  local start = M.omnifunc(1, "")
  if start < 0 or cursor[2] < start then
    return nil
  end
  local base = vim.api.nvim_get_current_line():sub(start + 1, cursor[2])
  local matches = M.omnifunc(0, base)
  -- Nothing to offer once the value is exactly the only match (e.g. right after accepting it)
  if #matches == 1 and matches[1]:lower() == base:lower() then
    matches = {}
  end
  return { start = start, base = base, matches = matches }
end

-- Whether blink.cmp drives the form's completion (see builds/blink_source.lua), loading it if
-- installed but not loaded yet
local function use_blink()
  local ok, blink = pcall(require, "blink.cmp")
  return ok and type(blink.add_source_provider) == "function"
    and require("workhorse.builds.blink_source").register()
end

-- Native menu: open (or narrow) it while typing the value of a field with choices, so they
-- show up like a dropdown
local function autocomplete(bufnr)
  local form = forms[bufnr]
  if not form or form.engine ~= "native" or vim.fn.mode() ~= "i" then
    return
  end
  local completion = M.choice_completion()
  if not completion then
    return
  end
  -- Moving through the menu inserts the selected item, and going back to the typed text
  -- repeats it: neither is typing, so leave the menu as is
  local typed = vim.api.nvim_win_get_cursor(0)[1] .. ":" .. completion.base
  if vim.fn.pumvisible() == 1 then
    if typed == form.completed or vim.fn.complete_info({ "selected" }).selected ~= -1 then
      return
    end
  end
  form.completed = typed
  if #completion.matches > 0 or vim.fn.pumvisible() == 1 then
    vim.fn.complete(completion.start + 1, completion.matches)
  end
end

-- Pick the completion engine on the first insert: blink.cmp when available, the native
-- menu otherwise (with blink.cmp, if loaded, kept out of the way)
local function setup_engine(bufnr)
  local form = forms[bufnr]
  if not form or form.engine then
    return
  end
  form.engine = use_blink() and "blink" or "native"
  if form.engine == "native" then
    -- Nothing selected until <Tab>, which inserts the item as it goes; <CR> takes the
    -- first item when none is selected
    vim.b[bufnr].completion = false
    vim.bo[bufnr].completeopt = "menuone,noselect"
  end
end

-- Navigation ------------------------------------------------------------------

-- Lines holding a "name: value" field, in order
local function field_lines(bufnr)
  local result = {}
  for lnum, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:match("^[^#%s][^:]*:") then
      table.insert(result, lnum)
    end
  end
  return result
end

--- Move the cursor to the end of the next (dir = 1) or previous (dir = -1) value
function M.jump(dir)
  local bufnr = vim.api.nvim_get_current_buf()
  local fields = field_lines(bufnr)
  if #fields == 0 then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local current = 0
  for i, lnum in ipairs(fields) do
    if lnum <= row then
      current = i
    end
  end
  if current == 0 and dir < 0 then
    current = 1
  end
  local target = fields[(current - 1 + dir) % #fields + 1]
  local line = vim.api.nvim_buf_get_lines(bufnr, target - 1, target, false)[1]
  -- "name:" without a space: add it, so typing starts after it
  if line:match(":$") then
    line = line .. " "
    vim.api.nvim_buf_set_lines(bufnr, target - 1, target, false, { line })
  end
  vim.api.nvim_win_set_cursor(0, { target, #line })
end

-- Insert-mode <Tab>/<S-Tab>: move in an open completion menu, jump between fields otherwise
local function insert_tab(dir)
  return function()
    local blink = package.loaded["blink.cmp"]
    if blink and blink.is_menu_visible and blink.is_menu_visible() then
      return ("<Cmd>lua require('blink.cmp').select_%s()<CR>"):format(dir > 0 and "next" or "prev")
    end
    if vim.fn.pumvisible() == 1 then
      return dir > 0 and "<C-n>" or "<C-p>"
    end
    return ("<Cmd>lua require('workhorse.builds.new_run').jump(%d)<CR>"):format(dir)
  end
end

-- Insert-mode <CR>: accept the selected item, or the first one when none is selected
local function insert_cr()
  local blink = package.loaded["blink.cmp"]
  if blink and blink.is_menu_visible and blink.is_menu_visible() then
    return "<Cmd>lua require('blink.cmp').select_and_accept()<CR>"
  end
  if vim.fn.pumvisible() == 0 then
    return "<CR>"
  end
  return vim.fn.complete_info({ "selected" }).selected == -1 and "<C-n><C-y>" or "<C-y>"
end

-- Window ----------------------------------------------------------------------

local function is_float(win)
  return vim.api.nvim_win_get_config(win).relative ~= ""
end

local function float_size(value, total)
  local n = value <= 1 and math.floor(total * value) or value
  return math.max(1, math.min(n, total))
end

local function float_config()
  local opts = config.get().builds.run_form
  local columns, lines = vim.o.columns - 2, vim.o.lines - vim.o.cmdheight - 2
  local width, height = float_size(opts.width, columns), float_size(opts.height, lines)
  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((lines - height) / 2),
    col = math.floor((columns - width) / 2),
    border = opts.border,
    title = " Workhorse: run new build ",
    title_pos = "center",
  }
end

-- Close the form: its floats close, its other windows go back to the previous buffer
local function close(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local form = forms[bufnr]
  local prev = form and form.prev
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if is_float(win) then
      pcall(vim.api.nvim_win_close, win, true)
    elseif prev and vim.api.nvim_buf_is_valid(prev) then
      vim.api.nvim_win_set_buf(win, prev)
    else
      vim.api.nvim_win_call(win, function()
        vim.cmd("enew")
      end)
    end
  end
  -- Closing its last window already wiped it (bufhidden=wipe)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

-- Submit ----------------------------------------------------------------------

-- Values to send (only those changed from the defaults), or a list of errors
local function collect(form, parsed)
  local errors = {}
  for _, line in ipairs(parsed.unknown) do
    table.insert(errors, "Not a 'name: value' line: " .. line)
  end
  local branch = parsed.branch or ""
  if branch == "" then
    table.insert(errors, "Branch is empty")
  end

  local params = {}
  for name, value in pairs(parsed.params) do
    local p = param_by_name(form, name)
    if not p then
      table.insert(errors, "Unknown parameter: " .. name)
    elseif value == "" and p.default == nil then
      table.insert(errors, "Parameter " .. name .. " is required")
    elseif value ~= display_value(p.default) or p.default == nil then
      if p.type == "boolean" then
        if value:lower() ~= "true" and value:lower() ~= "false" then
          table.insert(errors, "Parameter " .. name .. " must be true or false")
        end
        value = value:lower()
      elseif p.type == "number" and not tonumber(value) then
        table.insert(errors, "Parameter " .. name .. " must be a number")
      end
      if p.values and not vim.tbl_contains(vim.tbl_map(display_value, p.values), value) then
        table.insert(errors, "Parameter " .. name .. " must be one of: " .. table.concat(vim.tbl_map(display_value, p.values), ", "))
      end
      params[name] = p.type == "object" and value or (value:gsub("\\n", "\n"))
    end
  end
  -- Removing a required parameter's line leaves it without a value
  for _, p in ipairs(form.params) do
    if p.default == nil and parsed.params[p.name] == nil then
      table.insert(errors, "Parameter " .. p.name .. " is required")
    end
  end

  local variables = {}
  for name, value in pairs(parsed.variables) do
    local v = variable_by_name(form, name)
    if not v then
      table.insert(errors, "Variable " .. name .. " cannot be set at queue time")
    elseif value ~= v.value then
      variables[name] = value
    end
  end

  if #errors > 0 then
    return nil, errors
  end
  if not branch:match("^refs/") then
    branch = "refs/heads/" .. branch
  end
  return { branch = branch, parameters = params, variables = variables }
end

--- Queue the run described by the current form, after a confirmation
function M.submit(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local form = forms[bufnr]
  if not form then
    return
  end
  if form.queuing then
    vim.notify("Workhorse: Already queuing this run", vim.log.levels.INFO)
    return
  end
  local parsed = M.parse_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  local opts, errors = collect(form, parsed)
  if not opts then
    vim.notify("Workhorse: Cannot queue the run:\n  " .. table.concat(errors, "\n  "), vim.log.levels.ERROR)
    return
  end

  local changed = vim.tbl_count(opts.parameters) + vim.tbl_count(opts.variables)
  local prompt = ("Run %s on %s%s?"):format(
    form.definition.name,
    short_branch(opts.branch),
    changed > 0 and (" with " .. changed .. " changed value" .. (changed == 1 and "" or "s")) or ""
  )
  if vim.fn.confirm(prompt, "&Run\n&Cancel", 2) ~= 1 then
    return
  end

  form.queuing = true
  vim.notify("Workhorse: Queuing run...", vim.log.levels.INFO)
  builds_api.queue_build(form.definition.id, opts, function(run, err)
    if forms[bufnr] then
      forms[bufnr].queuing = false
    end
    if err or not run then
      vim.notify("Workhorse: Failed to queue run: " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end
    vim.notify("Workhorse: Queued run #" .. (run.build_number or run.id), vim.log.levels.INFO)
    close(bufnr)
    run.definition_name = run.definition_name or form.definition.name
    require("workhorse.builds").open_run(run, nil, { watch = true })
  end)
end

-- Loading ---------------------------------------------------------------------

-- Runtime parameters of a YAML pipeline at `branch` (Azure Repos only);
-- callback(params, err) with params = {} for classic pipelines
local function load_params(definition, branch, callback)
  if not definition.yaml_file then
    callback({})
    return
  end
  if definition.repository.type ~= "TfsGit" then
    callback(nil, "the YAML file is not in Azure Repos (" .. tostring(definition.repository.type) .. ")")
    return
  end
  builds_api.get_file(definition.repository.id, definition.yaml_file, branch, function(text, err)
    if not text then
      callback(nil, definition.yaml_file .. " on " .. short_branch(branch) .. ": " .. (err or "not found"))
      return
    end
    local ok, params = pcall(yaml.parameters, text)
    if not ok then
      callback(nil, definition.yaml_file .. ": " .. tostring(params))
      return
    end
    callback(params)
  end)
end

-- Re-read the parameters for the branch typed in the form, keeping the values entered
-- for parameters and variables that still exist
function M.reload(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local form = forms[bufnr]
  if not form then
    return
  end
  local values = M.parse_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  local branch = (values.branch and values.branch ~= "") and values.branch
    or form.definition.repository.default_branch or "master"
  -- Keep only the values the user changed, so new defaults of the branch show up
  for name, value in pairs(values.params) do
    local p = param_by_name(form, name)
    if p and value == display_value(p.default) then
      values.params[name] = nil
    end
  end
  load_params(form.definition, branch, function(params, err)
    if not forms[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    form.params, form.params_error = params or {}, err
    local cursor = vim.fn.win_findbuf(bufnr)[1] and vim.api.nvim_win_get_cursor(vim.fn.win_findbuf(bufnr)[1])
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, build_lines(form, values))
    decorate(bufnr)
    if cursor then
      local win = vim.fn.win_findbuf(bufnr)[1]
      vim.api.nvim_win_set_cursor(win, { math.min(cursor[1], vim.api.nvim_buf_line_count(bufnr)), cursor[2] })
    end
    vim.notify("Workhorse: Parameters reloaded from " .. short_branch(branch), vim.log.levels.INFO)
  end)
end

local function setup_keymaps(bufnr)
  local opts = { buffer = bufnr, silent = true }
  local function with_desc(desc, extra)
    return vim.tbl_extend("force", opts, { desc = "Workhorse: " .. desc }, extra or {})
  end
  vim.keymap.set("i", "<Tab>", insert_tab(1), with_desc("next field", { expr = true }))
  vim.keymap.set("i", "<S-Tab>", insert_tab(-1), with_desc("previous field", { expr = true }))
  vim.keymap.set("i", "<CR>", insert_cr, with_desc("accept the completion", { expr = true }))
  vim.keymap.set("n", "<Tab>", function()
    M.jump(1)
  end, with_desc("next field"))
  vim.keymap.set("n", "<S-Tab>", function()
    M.jump(-1)
  end, with_desc("previous field"))
  for _, lhs in ipairs({ "<CR>", "<leader><leader>" }) do
    vim.keymap.set("n", lhs, function()
      M.submit(bufnr)
    end, with_desc("queue the run"))
  end
  vim.keymap.set("n", "<leader>R", function()
    M.reload(bufnr)
  end, with_desc("reload parameters for the branch"))
  vim.keymap.set("n", "q", function()
    close(bufnr)
  end, with_desc("close", { nowait = true }))
  vim.keymap.set("n", "<Esc>", function()
    close(bufnr)
  end, with_desc("close", { nowait = true }))
end

local function create_buffer(form)
  counter = counter + 1
  local bufnr = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, bufnr, "Workhorse|run|" .. form.definition.id .. "|" .. counter)
  -- acwrite: :w queues the run (through BufWriteCmd) instead of writing a file
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, build_lines(form))
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].omnifunc = "v:lua.require'workhorse.builds.new_run'.omnifunc"
  vim.bo[bufnr].filetype = "workhorse-run"
  forms[bufnr] = form
  setup_keymaps(bufnr)

  local group = vim.api.nvim_create_augroup("workhorse_new_run_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = bufnr,
    callback = function()
      M.submit(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      decorate(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    buffer = bufnr,
    callback = function()
      setup_engine(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      autocomplete(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
        if is_float(win) then
          vim.api.nvim_win_set_config(win, float_config())
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function()
      forms[bufnr] = nil
      vim.schedule(function()
        pcall(vim.api.nvim_del_augroup_by_id, group)
      end)
    end,
  })
  decorate(bufnr)
  return bufnr
end

--- Open the form to queue a run of a pipeline (build definition)
function M.open(definition_id, definition_name)
  definition_id = tonumber(definition_id) or definition_id
  vim.notify("Workhorse: Loading pipeline " .. (definition_name or definition_id) .. "...", vim.log.levels.INFO)
  builds_api.get_definition(definition_id, function(definition, err)
    if err or not definition then
      vim.notify("Workhorse: Failed to load pipeline: " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end
    definition.name = definition.name or definition_name or ("Pipeline " .. definition_id)
    load_params(definition, definition.repository.default_branch or "master", function(params, params_err)
      local form = {
        definition = definition,
        params = params or {},
        params_error = params_err,
        prev = vim.api.nvim_get_current_buf(),
      }
      local bufnr = create_buffer(form)
      if config.get().builds.run_form.layout == "full" then
        vim.api.nvim_win_set_buf(0, bufnr)
      else
        vim.api.nvim_open_win(bufnr, true, float_config())
      end
      -- Start on the branch value
      vim.api.nvim_win_set_cursor(0, { 2, #vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1] })

      if definition.repository.type == "TfsGit" and definition.repository.id then
        builds_api.list_branches(definition.repository.id, function(branches)
          if forms[bufnr] then
            forms[bufnr].branches = branches
          end
        end)
      end
    end)
  end)
end

return M
