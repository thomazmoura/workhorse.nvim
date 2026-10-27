-- Form engine of the build forms ("Run new build", "New pipeline"): a buffer of "name: value"
-- lines in a float (or in place of the current buffer). <Tab>/<S-Tab> move between the values,
-- typing in a field with choices shows them like a dropdown (blink.cmp or the native menu), and
-- <CR> (normal mode) or <leader><leader> submits. The fields, their choices, highlights and what
-- submitting does come from the form's spec (see M.create).
local M = {}

local config = require("workhorse.config")
local choices = require("workhorse.ui.choices")

-- Shared by the forms, so the blink.cmp source (builds/blink_source.lua) covers all of them
M.FILETYPE = "workhorse-run"

-- Per-buffer form state: { spec, prev, ... } plus each form's own fields
local forms = {}

local counter = 0

--- Form state of a buffer (nil when it is not a form)
function M.get(bufnr)
  return forms[bufnr]
end

-- Completion ------------------------------------------------------------------

-- The completion engine is ui/choices.lua: each form attaches its spec.choices to it

--- Choices matching the value typed before the cursor (see ui/choices.lua)
function M.choice_completion()
  return choices.choice_completion()
end

--- Show the choices again after they changed (e.g. finished loading) while typing in the form
function M.refresh_completion(bufnr)
  choices.refresh(bufnr)
end

-- Navigation ------------------------------------------------------------------

-- Lines holding a "name: value" field, in order (line 1 is the form's title)
local function field_lines(bufnr)
  local result = {}
  for lnum, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if lnum > 1 and line:match("^[^#%s][^:]*:") then
      table.insert(result, lnum)
    end
  end
  return result
end

--- Move the cursor to the end of the next (dir = 1) or previous (dir = -1) value. `fields`
--- (default: the "name: value" lines of a form) lists the line numbers holding a value, in order;
--- with opts.at_start the cursor goes to the value's first character instead
function M.jump(dir, fields, opts)
  local bufnr = vim.api.nvim_get_current_buf()
  fields = fields or field_lines(bufnr)
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
  local col = #line
  if opts and opts.at_start then
    local value = line:find("%S", line:find(":", 1, true) + 1)
    col = value and value - 1 or #line
  end
  vim.api.nvim_win_set_cursor(0, { target, col })
  -- Inside a closed fold: open it
  vim.cmd("normal! zv")
end

--- Keys moving in the open completion menu (blink.cmp or native) to its next (dir = 1) or
--- previous item, nil when no menu is open
function M.menu_key(dir)
  local blink = package.loaded["blink.cmp"]
  if blink and blink.is_menu_visible and blink.is_menu_visible() then
    return ("<Cmd>lua require('blink.cmp').select_%s()<CR>"):format(dir > 0 and "next" or "prev")
  end
  if vim.fn.pumvisible() == 1 then
    return dir > 0 and "<C-n>" or "<C-p>"
  end
end

-- Insert-mode <Tab>/<S-Tab>: move in an open completion menu, jump between fields otherwise
local function insert_tab(dir)
  return function()
    local menu = M.menu_key(dir)
    if menu then
      return menu
    end
    return ("<Cmd>lua require('workhorse.builds.form').jump(%d)<CR>"):format(dir)
  end
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
  vim.keymap.set("i", "<CR>", choices.insert_cr, with_desc("accept the completion", { expr = true }))
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
---   submit(bufnr)  run by <CR> and <leader><leader> (not by :w)
---   keymaps(bufnr, with_desc)  optional extra keymaps
---   on_close(form)  optional, run once the form is closed, however it was closed
--- `form` is the form's state (see M.get), `name` the buffer name and `lines` its content
function M.create(spec, form, name, lines)
  counter = counter + 1
  local bufnr = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, bufnr, name .. "|" .. counter)
  -- acwrite: :w (e.g. an auto-save plugin's, on InsertLeave) does nothing instead of writing a
  -- file; only <CR> and <leader><leader> submit
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].filetype = M.FILETYPE
  form.spec = spec
  forms[bufnr] = form
  choices.attach(bufnr, { choices = spec.choices })
  setup_keymaps(bufnr, spec)

  local group = vim.api.nvim_create_augroup("workhorse_form_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = bufnr,
    callback = function()
      vim.bo[bufnr].modified = false
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
