-- Form engine of the build forms ("Run new build", "New pipeline"): a buffer of "name: value"
-- lines in a float (or in place of the current buffer). <Tab>/<S-Tab> move between the values,
-- typing in a field with choices shows them like a dropdown (blink.cmp or the native menu), and
-- <CR>, <leader><leader> (or :w) submits. The fields, their choices, highlights and what
-- submitting does come from the form's spec (see M.create).
local M = {}

local config = require("workhorse.config")

-- Shared by the forms, so the blink.cmp source (builds/blink_source.lua) covers all of them
M.FILETYPE = "workhorse-run"

-- Per-buffer form state: { spec, prev, engine, completed, ... } plus each form's own fields
local forms = {}

local counter = 0

--- Form state of a buffer (nil when it is not a form)
function M.get(bufnr)
  return forms[bufnr]
end

-- Completion ------------------------------------------------------------------

-- Choices of the field on line `lnum` (see spec.choices)
local function choices(bufnr, lnum)
  local form = forms[bufnr]
  if not form then
    return nil
  end
  return form.spec.choices(bufnr, lnum)
end

--- omnifunc of the forms (<C-x><C-o> on fields with choices)
function M.omnifunc(findstart, base)
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  if findstart == 1 then
    local colon = line:find(":")
    if not colon or not forms[bufnr] then
      return -3
    end
    local start = colon + #(line:sub(colon + 1):match("^%s*"))
    local _, list = choices(bufnr, lnum)
    if list then
      -- Complete the item after the last comma before the cursor
      local before = line:sub(start + 1, vim.api.nvim_win_get_cursor(0)[2])
      local after_comma = before:match(".*,()")
      if after_comma then
        start = start + after_comma - 1 + #(before:sub(after_comma):match("^%s*"))
      end
    end
    return start
  end
  -- Values starting with the text, then containing it, then fuzzy matches (best first, e.g.
  -- "fealog" for "feature/login-page")
  local prefix, rest, seen = {}, {}, {}
  local query = base:lower()
  local words = choices(bufnr, lnum) or {}
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

--- Choices matching the value typed before the cursor of the current window, for a field
--- with choices: { start = 0-based column of the value, base = typed text, matches = {...} }
--- or nil (another buffer, a free-text field, the cursor before the value)
function M.choice_completion()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  if not forms[bufnr] or not choices(bufnr, cursor[1]) then
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

--- Show the choices again after they changed (e.g. finished loading) while typing in the form
function M.refresh_completion(bufnr)
  local form = forms[bufnr]
  if not form or vim.api.nvim_get_current_buf() ~= bufnr or vim.fn.mode() ~= "i" then
    return
  end
  if form.engine == "native" then
    form.completed = nil
    autocomplete(bufnr)
  elseif form.engine == "blink" then
    local completion = M.choice_completion()
    if completion and #completion.matches > 0 then
      local blink = require("blink.cmp")
      if blink.is_menu_visible() then
        pcall(blink.hide)
      end
      vim.schedule(function()
        pcall(blink.show)
      end)
    end
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
    return ("<Cmd>lua require('workhorse.builds.form').jump(%d)<CR>"):format(dir)
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

local function float_config(title)
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
    title = title,
    title_pos = "center",
  }
end

--- Close a form: its floats close, its other windows go back to the previous buffer
function M.close(bufnr)
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

-- Buffer ----------------------------------------------------------------------

local function setup_keymaps(bufnr, spec)
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
      spec.submit(bufnr)
    end, with_desc(spec.submit_desc))
  end
  if spec.keymaps then
    spec.keymaps(bufnr, with_desc)
  end
  vim.keymap.set("n", "q", function()
    M.close(bufnr)
  end, with_desc("close", { nowait = true }))
  vim.keymap.set("n", "<Esc>", function()
    M.close(bufnr)
  end, with_desc("close", { nowait = true }))
end

--- Create the buffer of a form (not shown yet, see M.show). `spec`:
---   title        float title
---   submit_desc  description of the submit keymaps
---   choices(bufnr, lnum)  choices of the field on a line, nil for free text; a second result
---                true marks a comma-separated list, completed one item at a time
---   decorate(bufnr)  highlights and hints, run on every change
---   on_change(bufnr)  optional, run on every change before decorate
---   submit(bufnr)  run by <CR>, <leader><leader> and :w
---   keymaps(bufnr, with_desc)  optional extra keymaps
---   on_close(form)  optional, run once the form is closed, however it was closed
--- `form` is the form's state (see M.get), `name` the buffer name and `lines` its content
function M.create(spec, form, name, lines)
  counter = counter + 1
  local bufnr = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, bufnr, name .. "|" .. counter)
  -- acwrite: :w submits (through BufWriteCmd) instead of writing a file
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].omnifunc = "v:lua.require'workhorse.builds.form'.omnifunc"
  vim.bo[bufnr].filetype = M.FILETYPE
  form.spec = spec
  forms[bufnr] = form
  setup_keymaps(bufnr, spec)

  local group = vim.api.nvim_create_augroup("workhorse_form_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = bufnr,
    callback = function()
      spec.submit(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      if spec.on_change then
        spec.on_change(bufnr)
      end
      spec.decorate(bufnr)
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
  -- A float left behind (e.g. <C-h> to another window) would linger over it: close the form.
  -- Completion menus and the confirmation prompt keep the focus, so they don't trigger this
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = bufnr,
    callback = function()
      if is_float(vim.api.nvim_get_current_win()) then
        -- Windows can't be closed while leaving one
        vim.schedule(function()
          M.close(bufnr)
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
        if is_float(win) then
          vim.api.nvim_win_set_config(win, float_config(spec.title))
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function()
      local form = forms[bufnr]
      forms[bufnr] = nil
      vim.schedule(function()
        pcall(vim.api.nvim_del_augroup_by_id, group)
        if spec.on_close and form then
          spec.on_close(form)
        end
      end)
    end,
  })
  spec.decorate(bufnr)
  return bufnr
end

--- Show a form created by M.create (builds.run_form.layout: a float or the current window),
--- with the cursor at `cursor` ({ row, col }) when given
function M.show(bufnr, cursor)
  if config.get().builds.run_form.layout == "full" then
    vim.api.nvim_win_set_buf(0, bufnr)
  else
    vim.api.nvim_open_win(bufnr, true, float_config(forms[bufnr].spec.title))
  end
  if cursor then
    vim.api.nvim_win_set_cursor(0, cursor)
  end
end

return M
