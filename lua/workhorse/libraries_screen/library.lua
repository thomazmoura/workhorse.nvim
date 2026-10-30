-- Screen of one library (variable group), opened by <CR> on the libraries list: one editable
-- buffer styled like the repository screen, a "name" title (<CR> on it goes back to the list)
-- and three sections, each under its title line with its lines indented one level:
--
--   my-library                       description · Thomaz Moura, 27/10/26
--   ───── ◇ ─────           (virtual lines: never in the text; frozen while scrolling)
--   Variables               (libraries_screen/variables.lua)
--     ApiUrl: https://example.com
--     Password (secret):
--
--   ───── ◇ ─────
--
--   Pipelines               (libraries_screen/pipelines.lua)
--     Open access: off
--     CI\my-pipeline
--   Security                (libraries_screen/security.lua)
--     [GTI]\Project Administrators: Administrator (inherited)
--
-- Each section module only reads and renders the lines of its own section (M.section_lines,
-- M.set_section), with buffer line numbers; the section's indent is taken off the lines it reads
-- and put back on the lines it writes. Saving confirms the changes of every section in one list,
-- then applies them. A draft (a library typed on the list, not created yet) only has variables:
-- its first save creates it, and its pipelines and security load then.
local M = {}

local guides = require("workhorse.buffer_tree.guides")
local pinned = require("workhorse.ui.pinned")
local choices = require("workhorse.ui.choices")
local libraries_api = require("workhorse.api.libraries")

local SECTIONS = { "variables", "pipelines", "security" }
local LABELS = { variables = "Variables", pipelines = "Pipelines", security = "Security" }
local MODULES = {
  variables = "workhorse.libraries_screen.variables",
  pipelines = "workhorse.libraries_screen.pipelines",
  security = "workhorse.libraries_screen.security",
}
local SECTION_OF_LABEL = {}
for _, section in ipairs(SECTIONS) do
  SECTION_OF_LABEL[LABELS[section]:lower()] = section
end

local ns = vim.api.nvim_create_namespace("workhorse_library_headers")
-- Separators, drawn apart so a resize redraws them alone
local rules_ns = vim.api.nvim_create_namespace("workhorse_library_rules")

-- [group id] = bufnr
local screens = {}
-- [bufnr] = group (shared with the sections, updated in place)
local group_of_buffer = {}

local function notify(msg, level)
  vim.notify("Workhorse: " .. msg, level or vim.log.levels.INFO)
end

M.notify = notify

local function module(section)
  return require(MODULES[section])
end

-- Sections ----------------------------------------------------------------------

--- Section named by a header line (its title, unindented), nil for any other line
function M.parse_header(line)
  local label = (line or ""):match("^(%a+)%s*$")
  return label and SECTION_OF_LABEL[label:lower()]
end

-- Section named by buffer line `lnum`, never the title (a library may be named "Security")
local function header_at(lnum, line)
  return lnum > 1 and M.parse_header(line) or nil
end

-- Line 1 is the title unless it was deleted (a blank line or a section header took its place)
local function is_title(bufnr, lnum)
  if lnum ~= 1 then
    return false
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
  local group = group_of_buffer[bufnr]
  return (group and line == group.name) or (not line:match("^%s*$") and not M.parse_header(line))
end

--- `line` without the indent of its section (one level), as the section modules read it
function M.dedent(line)
  return line:sub(math.min(#line:match("^ *"), guides.width()) + 1)
end

--- `lines` (of a section module) with the indent of their section, blank ones left blank
function M.indent(lines)
  local prefix = guides.prefix(1)
  return vim.tbl_map(function(line)
    return line:match("^%s*$") and "" or prefix .. line
  end, lines)
end

-- { [section] = header lnum }
local function headers(bufnr)
  local result = {}
  for lnum, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local section = header_at(lnum, line)
    if section and not result[section] then
      result[section] = lnum
    end
  end
  return result
end

--- Lines first..last of `section` (after its header, up to the next header), nil when its
--- header is gone
function M.section_range(bufnr, section)
  local all = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local first
  for lnum, line in ipairs(all) do
    local found = header_at(lnum, line)
    if first and found then
      return first, lnum - 1
    elseif found == section then
      first = lnum + 1
    end
  end
  if first then
    return first, #all
  end
end

--- Lines of `section`, without its indent, and the buffer line number before its first one (its
--- header: line i of the result is buffer line offset + i); nil when its header is gone
function M.section_lines(bufnr, section)
  local first, last = M.section_range(bufnr, section)
  if not first then
    return nil
  end
  return vim.tbl_map(M.dedent, vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)), first - 1
end

--- Section of buffer line `lnum`, nil above the first header
function M.section_at(bufnr, lnum)
  local current
  for l, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, lnum, false)) do
    current = header_at(l, line) or current
  end
  return current
end

--- Replace the lines of `section` (a blank line keeps it apart from the next one). A section
--- whose header was deleted gets it back
function M.set_section(bufnr, section, lines)
  lines = M.indent(lines)
  local index = vim.fn.index(SECTIONS, section) + 1
  if index < #SECTIONS then
    table.insert(lines, "")
  end
  local first, last = M.section_range(bufnr, section)
  if first then
    vim.api.nvim_buf_set_lines(bufnr, first - 1, last, false, lines)
    return
  end
  -- Before the header of the next section there is, or at the end
  local found = headers(bufnr)
  local row = vim.api.nvim_buf_line_count(bufnr)
  for i = index + 1, #SECTIONS do
    if found[SECTIONS[i]] then
      row = found[SECTIONS[i]] - 1
      break
    end
  end
  table.insert(lines, 1, LABELS[section])
  vim.api.nvim_buf_set_lines(bufnr, row, row, false, lines)
end

--- Error of a section whose header was deleted
function M.missing_header(section)
  return ("The %s line is missing (<leader>R reloads)"):format(LABELS[section])
end

local function pending(bufnr)
  for _, section in ipairs(SECTIONS) do
    if module(section).pending(bufnr) then
      return true
    end
  end
  return false
end

--- After a section was re-rendered: the buffer is modified when a section still has changes
function M.update_modified(bufnr)
  vim.bo[bufnr].modified = pending(bufnr)
end

local function window_width(bufnr)
  local win = vim.fn.win_findbuf(bufnr)[1]
  local width = win and vim.api.nvim_win_get_width(win) or vim.o.columns
  if win then
    width = width - vim.fn.getwininfo(win)[1].textoff
  end
  return width
end

-- The separators ("───── ◇ ─────" across the window): under the title, and above every section
-- title but the first one (after its blank line)
local function draw_rules(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, rules_ns, 0, -1)
  local rule = require("workhorse.ui.header").rule(window_width(bufnr))
  if is_title(bufnr, 1) then
    vim.api.nvim_buf_set_extmark(bufnr, rules_ns, 0, 0, { virt_lines = { rule } })
  end
  local found = headers(bufnr)
  local first
  for _, section in ipairs(SECTIONS) do
    if found[section] then
      first = first or section
      if section ~= first then
        vim.api.nvim_buf_set_extmark(bufnr, rules_ns, found[section] - 1, 0,
          { virt_lines = { rule, { { "" } } }, virt_lines_above = true })
      end
    end
  end
  -- The title and the rule under it stay frozen at the top while scrolling
  pinned.schedule_refresh(bufnr)
end

-- Right side of the title: the description, Key Vault, and who last changed it, when
local function title_meta(group)
  if not group.id then
    return "new library: saving creates it", "DiagnosticOk"
  end
  local parts = {}
  if group.description ~= "" then
    table.insert(parts, group.description)
  end
  if group.type ~= "Vsts" then
    table.insert(parts, "linked to Azure Key Vault")
  end
  if group.modified_by then
    local date = group.modified_on and require("workhorse.api.builds").format_date(group.modified_on)
    table.insert(parts, group.modified_by .. (date and (", " .. date) or ""))
  end
  return table.concat(parts, " · "), "WorkhorseBuildMeta"
end

--- Highlights and hints of the whole buffer
function M.decorate(bufnr)
  local group = group_of_buffer[bufnr]
  if not group then
    return
  end
  guides.draw(bufnr, { boundary = M.parse_header })
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if is_title(bufnr, 1) then
    local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
    local meta, hl = title_meta(group)
    vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, { end_col = #line, hl_group = "WorkhorseBuildHeader" })
    vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, { virt_text = { { meta, hl } }, virt_text_pos = "right_align" })
  end
  for _, lnum in pairs(headers(bufnr)) do
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, { end_col = #line, hl_group = "WorkhorseRunSection" })
    vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, { end_col = #line, hl_group = "WorkhorseBold",
      priority = 4097 })
  end
  draw_rules(bufnr)
  for _, section in ipairs(SECTIONS) do
    module(section).decorate(bufnr)
  end
end

--- Hint on the header of `section` (e.g. why it is empty), drawn by the section's decorate
function M.header_hint(bufnr, section, text, hl)
  local lnum = headers(bufnr)[section]
  if lnum then
    vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, { virt_text = { { "  " .. text, hl or "WorkhorseRunHint" } } })
  end
end

-- Move the cursor `count` section headers down (or up with a negative count)
local function jump(bufnr, count)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lnums = vim.tbl_values(headers(bufnr))
  table.sort(lnums)
  local target
  if count > 0 then
    for _, lnum in ipairs(lnums) do
      if lnum > row then
        target = lnum
        count = count - 1
        if count == 0 then
          break
        end
      end
    end
  else
    for i = #lnums, 1, -1 do
      if lnums[i] < row then
        target = lnums[i]
        count = count + 1
        if count == 0 then
          break
        end
      end
    end
  end
  if target then
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  end
end

-- Lines holding a value ("key: value", e.g. a variable or a role), in order
local function value_lines(bufnr)
  local result = {}
  for lnum, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if lnum > 1 and not M.parse_header(line) and line:match("^%s*[^%s:][^:]*:") then
      table.insert(result, lnum)
    end
  end
  return result
end

--- Move the cursor to the start of the next (dir = 1) or previous (dir = -1) value, like <Tab>
--- on the build forms
function M.jump_value(dir)
  require("workhorse.builds.form").jump(dir, value_lines(vim.api.nvim_get_current_buf()), { at_start = true })
end

local function goto_section(bufnr, section)
  local lnum = headers(bufnr)[section]
  if lnum then
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    vim.cmd("normal! zt")
  end
end

-- Winbar --------------------------------------------------------------------------

function M.winbar()
  local win = vim.g.statusline_winid or vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(win)
  local group = group_of_buffer[bufnr]
  if not group then
    return ""
  end
  local current = M.section_at(bufnr, vim.api.nvim_win_get_cursor(win)[1]) or SECTIONS[1]
  local parts = {}
  for i, section in ipairs(SECTIONS) do
    local hl = section == current and "%#WorkhorsePRTabSel#" or "%#WorkhorsePRTab#"
    table.insert(parts, "%" .. i .. "@v:lua.WorkhorseLibrarySectionClick@" .. hl .. " " .. LABELS[section] .. " %X")
  end
  local name = group.name:gsub("%%", "%%%%")
  return table.concat(parts, "%#WorkhorsePRTab#│") .. "%#WorkhorsePRTab#%=%#WorkhorseBuildMeta# " .. name .. " "
end

local WINBAR = "%{%v:lua.require'workhorse.libraries_screen.library'.winbar()%}"

function _G.WorkhorseLibrarySectionClick(index)
  local win = vim.fn.getmousepos().winid
  if win and win ~= 0 and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    local bufnr = vim.api.nvim_get_current_buf()
    if group_of_buffer[bufnr] then
      goto_section(bufnr, SECTIONS[index])
    end
  end
end

-- Buffer ----------------------------------------------------------------------------

-- Put the title line back when it was deleted or edited (or the library renamed)
local function ensure_title(bufnr)
  local text = group_of_buffer[bufnr].name
  local first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
  if first == text then
    return
  end
  if is_title(bufnr, 1) then
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { text })
  else
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { text, "" })
  end
  M.update_modified(bufnr)
end

--- Replace the screen's group with `fresh`, in place (the sections share the table), and its
--- title with its name
function M.update_group(bufnr, fresh)
  local current = group_of_buffer[bufnr]
  if not current then
    return
  end
  if current ~= fresh then
    for k in pairs(current) do
      current[k] = nil
    end
    for k, v in pairs(fresh) do
      current[k] = v
    end
  end
  ensure_title(bufnr)
end

-- Completion goes to the module of the line's section
local function in_section(bufnr, lnum, fn)
  local section = M.section_at(bufnr, lnum)
  if section and not header_at(lnum, vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]) then
    return fn(module(section))
  end
end

-- Save ------------------------------------------------------------------------------

--- Confirm the changes of every section in one list, then apply them section by section (the
--- variables first: creating a draft gives the others a library to work on)
function M.save(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local group = group_of_buffer[bufnr]
  if not group then
    return
  end
  local prepared, errors = {}, {}
  for _, section in ipairs(SECTIONS) do
    local result, err = module(section).prepare(bufnr)
    if err then
      table.insert(errors, LABELS[section] .. ":\n" .. err)
    elseif result and #result.entries > 0 then
      table.insert(prepared, { section = section, result = result })
    end
  end
  if #errors > 0 then
    notify(table.concat(errors, "\n"), vim.log.levels.WARN)
    return
  end
  if #prepared == 0 then
    vim.bo[bufnr].modified = false
    notify("No changes to apply")
    return
  end
  local entries = {}
  for _, p in ipairs(prepared) do
    table.insert(entries, { text = LABELS[p.section], hl = "WorkhorseBuildHeader" })
    vim.list_extend(entries, p.result.entries)
  end
  local draft = not group.id
  local title = (draft and "Create library " or "Changes to ") .. group.name
  require("workhorse.ui.list_confirm").show(title, entries, function(confirmed)
    if not confirmed then
      return
    end
    local function run(index)
      if prepared[index] then
        return prepared[index].result.apply(function()
          run(index + 1)
        end)
      end
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      if draft and group.id then
        -- Created: a library screen like any other from now on
        screens[group.id] = bufnr
        pcall(vim.api.nvim_buf_set_name, bufnr, "Workhorse|library|" .. group.name)
        for _, section in ipairs(SECTIONS) do
          if section ~= "variables" then
            module(section).reload(bufnr)
          end
        end
      end
      ensure_title(bufnr)
      M.decorate(bufnr)
      -- The list shows the names and variable counts
      require("workhorse.libraries_screen").changed()
    end
    run(1)
  end)
end

--- Reload every section of the library screen `bufnr` (default: current), asking first when
--- there are unsaved changes; false when it is not one
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not group_of_buffer[bufnr] then
    return false
  end
  for _, section in ipairs(SECTIONS) do
    if module(section).saving(bufnr) then
      notify("Wait for the save to finish", vim.log.levels.WARN)
      return true
    end
  end
  if vim.bo[bufnr].modified and vim.fn.confirm("Discard the pending changes and reload?", "&Discard\n&Cancel", 2) ~= 1 then
    return true
  end
  ensure_title(bufnr)
  for _, section in ipairs(SECTIONS) do
    module(section).reload(bufnr)
  end
  return true
end

local function setup_keymaps(bufnr, group)
  local function map(lhs, fn, desc, mode)
    vim.keymap.set(mode or "n", lhs, fn, { buffer = bufnr, silent = true, desc = "Workhorse: " .. desc })
  end
  map("<leader><leader>", function()
    M.save(bufnr)
  end, "apply the changes")
  map("<leader>R", function()
    M.refresh(bufnr)
  end, "reload the library screen")
  -- <CR> goes back to the list on the title; elsewhere it moves down as usual
  map("<CR>", function()
    local count = vim.v.count1
    if is_title(bufnr, vim.api.nvim_win_get_cursor(0)[1]) then
      require("workhorse.libraries_screen").open()
      return
    end
    vim.cmd("normal! " .. count .. "+")
  end, "back to the libraries list (on the title)")
  map("}", function()
    jump(bufnr, vim.v.count1)
  end, "next section", { "n", "x", "o" })
  map("{", function()
    jump(bufnr, -vim.v.count1)
  end, "previous section", { "n", "x", "o" })
  for i, section in ipairs(SECTIONS) do
    map("g" .. i, function()
      goto_section(bufnr, section)
    end, LABELS[section] .. " section")
  end
  map("-", function()
    require("workhorse.libraries_screen").open()
  end, "back to the libraries list")
  local function open_web()
    require("workhorse.builds").open_url(libraries_api.web_url(group.id))
  end
  map("gw", open_web, "open the library in the browser")
  map("gb", open_web, "open the library in the browser")
  require("workhorse.builds").map_yank(bufnr, open_web, "the library")
  map("<leader>wR", function()
    require("workhorse.identities").update(function(data)
      if data and vim.api.nvim_buf_is_valid(bufnr) then
        M.decorate(bufnr)
      end
    end)
  end, "update the identity cache")
  map("<Tab>", function()
    M.jump_value(1)
  end, "next value")
  map("<S-Tab>", function()
    M.jump_value(-1)
  end, "previous value")
  -- Insert mode: move in an open completion menu; indent on a line still blank before the
  -- cursor; jump to the next value otherwise
  for dir, lhs in pairs({ [1] = "<Tab>", [-1] = "<S-Tab>" }) do
    vim.keymap.set("i", lhs, function()
      local menu = require("workhorse.builds.form").menu_key(dir)
      if menu then
        return menu
      end
      local col = vim.api.nvim_win_get_cursor(0)[2]
      if vim.api.nvim_get_current_line():sub(1, col):match("^%s*$") then
        return dir > 0 and "<C-t>" or "<C-d>"
      end
      return ("<Cmd>lua require('workhorse.libraries_screen.library').jump_value(%d)<CR>"):format(dir)
    end, { buffer = bufnr, silent = true, expr = true, desc = "Workhorse: " .. (dir > 0 and "next" or "previous") .. " value" })
  end
  -- Accept a completion with <CR>; a plain new line otherwise
  vim.keymap.set("i", "<CR>", choices.insert_cr, { buffer = bufnr, silent = true, expr = true,
    desc = "Workhorse: accept the completion" })
  for _, section in ipairs(SECTIONS) do
    if module(section).keymaps then
      module(section).keymaps(bufnr, map)
    end
  end
end

local function setup_autocmds(bufnr)
  local group = vim.api.nvim_create_augroup("workhorse_library_screen_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = bufnr,
    callback = function()
      M.save(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.decorate(bufnr)
    end,
  })
  -- The winbar shows the section of the cursor
  local last
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = bufnr,
    callback = function()
      local section = M.section_at(bufnr, vim.api.nvim_win_get_cursor(0)[1])
      if section ~= last then
        last = section
        vim.cmd("redrawstatus")
      end
    end,
  })
  -- The separators span the window
  vim.api.nvim_create_autocmd({ "BufWinEnter", "VimResized", "WinResized" }, {
    group = group,
    callback = function()
      if vim.api.nvim_buf_is_valid(bufnr) and #vim.fn.win_findbuf(bufnr) > 0 then
        draw_rules(bufnr)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
      local library = group_of_buffer[bufnr]
      group_of_buffer[bufnr] = nil
      if library and library.id and screens[library.id] == bufnr then
        screens[library.id] = nil
      end
    end,
  })
end

local function create(group)
  local bufnr = vim.api.nvim_create_buf(true, false)
  pcall(vim.api.nvim_buf_set_name, bufnr, "Workhorse|library|" .. group.name .. (group.id and "" or "|new"))
  -- acwrite: :w saves (through BufWriteCmd) instead of writing a file
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "workhorse-library"
  group_of_buffer[bufnr] = group
  if group.id then
    screens[group.id] = bufnr
  end
  guides.setup_buffer(bufnr)
  choices.attach(bufnr, {
    choices = function(b, lnum)
      return in_section(b, lnum, function(m)
        return m.choices(b, lnum)
      end)
    end,
    start = function(line, lnum)
      if header_at(lnum, line) then
        return nil
      end
      local section = M.section_at(bufnr, lnum)
      return section and module(section).start(line, lnum)
    end,
  })
  setup_keymaps(bufnr, group)
  setup_autocmds(bufnr)
  pinned.attach(bufnr, function()
    return is_title(bufnr, 1) and 1 or 0
  end)

  local lines = { group.name }
  for i, section in ipairs(SECTIONS) do
    table.insert(lines, LABELS[section])
    table.insert(lines, guides.prefix(1) .. "Loading " .. LABELS[section]:lower() .. "...")
    if i < #SECTIONS then
      table.insert(lines, "")
    end
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
  for _, section in ipairs(SECTIONS) do
    module(section).attach(bufnr, group)
  end
  return bufnr
end

--- Open the screen of `group` (its existing buffer, with its pending edits, when there is one).
--- A group without an id is a draft: saving creates it
function M.open(group)
  local bufnr = group.id and screens[group.id]
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_win_set_buf(0, bufnr)
    ensure_title(bufnr)
    M.decorate(bufnr)
    return bufnr
  end
  bufnr = create(group)
  vim.api.nvim_win_set_buf(0, bufnr)
  M.decorate(bufnr)
  for _, section in ipairs(SECTIONS) do
    module(section).reload(bufnr)
  end
  return bufnr
end

--- The library shown by `bufnr`, nil when it is not a library screen
function M.group_of(bufnr)
  return group_of_buffer[bufnr]
end

-- Library windows show the sections in their winbar; it is taken off again when the window moves
-- on to another buffer
vim.api.nvim_create_autocmd("BufWinEnter", {
  group = vim.api.nvim_create_augroup("workhorse_library_winbar", { clear = true }),
  callback = function(args)
    local win = vim.api.nvim_get_current_win()
    if group_of_buffer[args.buf] then
      vim.api.nvim_set_option_value("winbar", WINBAR, { scope = "local", win = win })
    elseif vim.wo[win].winbar == WINBAR then
      vim.api.nvim_set_option_value("winbar", "", { scope = "local", win = win })
    end
  end,
})

return M
