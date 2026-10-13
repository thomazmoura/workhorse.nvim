-- Screen of one repository, opened by <CR> on the repositories list: one editable buffer with
-- two sections, each under its header line:
--
--   ══ [Security] ══      (repos_screen/security.lua)
--   ...
--   ══ [Policies] ══      (repos_screen/policies.lua)
--   ...
--
-- Each section module only reads and renders the lines of its own section (M.section_lines,
-- M.set_section), with buffer line numbers. Saving confirms the changes of both sections in one
-- list, then applies them. { and } move between the sections; the winbar names them (clickable).
local M = {}

local fold = require("workhorse.fold")
local guides = require("workhorse.buffer_tree.guides")
local choices = require("workhorse.ui.choices")
local parse_indent = require("workhorse.buffer_tree.parser").parse_indent

local SECTIONS = { "security", "policies" }
local LABELS = { security = "Security", policies = "Policies" }
local MODULES = { security = "workhorse.repos_screen.security", policies = "workhorse.repos_screen.policies" }
local SECTION_OF_LABEL = {}
for _, section in ipairs(SECTIONS) do
  SECTION_OF_LABEL[LABELS[section]:lower()] = section
end

local ns = vim.api.nvim_create_namespace("workhorse_repo_headers")

-- [repo id] = bufnr
local screens = {}
-- [bufnr] = repo
local repo_of_buffer = {}

local function notify(msg, level)
  vim.notify("Workhorse: " .. msg, level or vim.log.levels.INFO)
end

local function module(section)
  return require(MODULES[section])
end

-- Sections ----------------------------------------------------------------------

local function header(section)
  return "══ [" .. LABELS[section] .. "] ══"
end

--- Section named by a header line, nil for any other line
function M.parse_header(line)
  local label = (line or ""):match("^%s*══+ %[(.-)%] ══+%s*$")
  return label and SECTION_OF_LABEL[label:lower()]
end

-- { [section] = header lnum }
local function headers(bufnr)
  local result = {}
  for lnum, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local section = M.parse_header(line)
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
    local found = M.parse_header(line)
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

--- Lines of `section` and the buffer line number before its first one (line i of the result is
--- buffer line offset + i); nil when its header is gone
function M.section_lines(bufnr, section)
  local first, last = M.section_range(bufnr, section)
  if not first then
    return nil
  end
  return vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false), first - 1
end

--- Section of buffer line `lnum`, nil above the first header
function M.section_at(bufnr, lnum)
  local current
  for l, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, lnum, false)) do
    current = M.parse_header(line) or current
    if l == lnum then
      break
    end
  end
  return current
end

--- Replace the lines of `section` (a blank line keeps it apart from the next one). A section
--- whose header was deleted gets it back
function M.set_section(bufnr, section, lines)
  lines = vim.deepcopy(lines)
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
  table.insert(lines, 1, header(section))
  vim.api.nvim_buf_set_lines(bufnr, row, row, false, lines)
end

--- Error of a section whose header was deleted
function M.missing_header(section)
  return ("The %s line is missing (<leader>R reloads)"):format(header(section))
end

-- Whether the buffer has changes to save, in any section
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

--- Highlights and hints of the whole buffer
function M.decorate(bufnr)
  if not repo_of_buffer[bufnr] then
    return
  end
  guides.draw(bufnr, { boundary = M.parse_header })
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for section, lnum in pairs(headers(bufnr)) do
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, { end_col = #line, hl_group = "WorkhorseBuildHeader" })
    if section == "security" then
      vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, { virt_text = { { "  " .. repo_of_buffer[bufnr].name,
        "WorkhorseBuildMeta" } } })
    end
  end
  for _, section in ipairs(SECTIONS) do
    module(section).decorate(bufnr)
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

-- Lines holding a value ("key: value", e.g. a permission or a policy), in order
local function value_lines(bufnr)
  local result = {}
  for lnum, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if not M.parse_header(line) and line:match("^%s*[^%s:][^:]*:") then
      table.insert(result, lnum)
    end
  end
  return result
end

--- Move the cursor to the start of the next (dir = 1) or previous (dir = -1) value (the first
--- character after the ":"), like <Tab> on the build forms
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
  local repo = repo_of_buffer[bufnr]
  if not repo then
    return ""
  end
  local current = M.section_at(bufnr, vim.api.nvim_win_get_cursor(win)[1]) or SECTIONS[1]
  local parts = {}
  for i, section in ipairs(SECTIONS) do
    local hl = section == current and "%#WorkhorsePRTabSel#" or "%#WorkhorsePRTab#"
    table.insert(parts, "%" .. i .. "@v:lua.WorkhorseRepoSectionClick@" .. hl .. " " .. LABELS[section] .. " %X")
  end
  local name = repo.name:gsub("%%", "%%%%")
  return table.concat(parts, "%#WorkhorsePRTab#│") .. "%#WorkhorsePRTab#%=%#WorkhorseBuildMeta# " .. name .. " "
end

local WINBAR = "%{%v:lua.require'workhorse.repos_screen.repo'.winbar()%}"

function _G.WorkhorseRepoSectionClick(index)
  local win = vim.fn.getmousepos().winid
  if win and win ~= 0 and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    local bufnr = vim.api.nvim_get_current_buf()
    if repo_of_buffer[bufnr] then
      goto_section(bufnr, SECTIONS[index])
    end
  end
end

-- Buffer ----------------------------------------------------------------------------

-- Settings page of the repository in the web UI, on the section's page
local function web_url(repo, section)
  local config = require("workhorse.config").get()
  local server = (config.server_url or ""):gsub("/$", "")
  local url_encode = require("workhorse.api.builds").url_encode
  return ("%s/%s/_settings/repositories?repo=%s&_a=%s"):format(server, url_encode(repo.project and repo.project.name
    or config.project), repo.id, section == "policies" and "policies" or "permissions")
end

-- Completion and folds go to the module of the line's section
local function in_section(bufnr, lnum, fn)
  local section = M.section_at(bufnr, lnum)
  if section and not M.parse_header(vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]) then
    return fn(module(section))
  end
end

-- Save ------------------------------------------------------------------------------

--- Confirm the changes of every section in one list, then apply them section by section
function M.save(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local repo = repo_of_buffer[bufnr]
  if not repo then
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
    table.insert(entries, { text = header(p.section), hl = "WorkhorseBuildHeader" })
    vim.list_extend(entries, p.result.entries)
  end
  require("workhorse.ui.list_confirm").show("Changes to " .. repo.name, entries, function(confirmed)
    if not confirmed then
      return
    end
    local function run(index)
      if prepared[index] then
        prepared[index].result.apply(function()
          run(index + 1)
        end)
      end
    end
    run(1)
  end)
end

--- Reload every section of the repository screen `bufnr` (default: current), asking first when
--- there are unsaved changes; false when it is not one
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not repo_of_buffer[bufnr] then
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
  for _, section in ipairs(SECTIONS) do
    module(section).reload(bufnr)
  end
  return true
end

local function setup_keymaps(bufnr, repo)
  local function map(lhs, fn, desc, mode)
    vim.keymap.set(mode or "n", lhs, fn, { buffer = bufnr, silent = true, desc = "Workhorse: " .. desc })
  end
  map("<leader><leader>", function()
    M.save(bufnr)
  end, "apply the changes")
  map("<leader>R", function()
    M.refresh(bufnr)
  end, "reload the repository screen")
  map("<Space>", function()
    fold.toggle(bufnr)
  end, "fold or unfold")
  -- <CR> folds like <Space> on a line with a fold; elsewhere it moves down as usual
  map("<CR>", function()
    local count = vim.v.count1
    if fold.toggle(bufnr) then
      return
    end
    vim.cmd("normal! " .. count .. "+")
  end, "fold or unfold")
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
    require("workhorse.repos_screen").open()
  end, "back to the repositories list")
  map("gw", function()
    vim.ui.open(web_url(repo, M.section_at(bufnr, vim.api.nvim_win_get_cursor(0)[1])))
  end, "open the repository settings in the browser")
  map("<leader>wR", function()
    require("workhorse.identities").update(function(data)
      if data and vim.api.nvim_buf_is_valid(bufnr) then
        M.decorate(bufnr)
      end
    end)
    require("workhorse.repos").update()
  end, "update the identity and repository caches")
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
      return ("<Cmd>lua require('workhorse.repos_screen.repo').jump_value(%d)<CR>"):format(dir)
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
  local group = vim.api.nvim_create_augroup("workhorse_repo_screen_" .. bufnr, { clear = true })
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
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      local repo = repo_of_buffer[bufnr]
      repo_of_buffer[bufnr] = nil
      if repo and screens[repo.id] == bufnr then
        screens[repo.id] = nil
      end
    end,
  })
end

local function create(repo)
  local bufnr = vim.api.nvim_create_buf(true, false)
  pcall(vim.api.nvim_buf_set_name, bufnr, "Workhorse|repo|" .. repo.name)
  -- acwrite: :w saves (through BufWriteCmd) instead of writing a file
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "workhorse-repo"
  repo_of_buffer[bufnr] = repo
  screens[repo.id] = bufnr
  guides.setup_buffer(bufnr)
  fold.attach(bufnr, {
    boundary = M.parse_header,
    summary = function(b, first, last)
      return in_section(b, first - 1, function(m)
        return m.summary(b, first, last)
      end) or ""
    end,
    -- Lines are named across reloads by their section and the lines they are under
    keys = function(b)
      local result, section, path = {}, nil, {}
      for lnum, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
        local found = M.parse_header(line)
        if found then
          section, path = found, {}
        elseif section and not line:match("^%s*$") then
          local level, rest = parse_indent(line)
          for i = 1, level do
            path[i] = path[i] or ""
          end
          path[level + 1] = vim.trim(rest)
          for i = #path, level + 2, -1 do
            path[i] = nil
          end
          result[lnum] = section .. ":" .. table.concat(path, "\t")
        end
      end
      return result
    end,
  })
  choices.attach(bufnr, {
    choices = function(b, lnum)
      return in_section(b, lnum, function(m)
        return m.choices(b, lnum)
      end)
    end,
    start = function(line, lnum)
      if M.parse_header(line) then
        return nil
      end
      local section = M.section_at(bufnr, lnum)
      return section and module(section).start(line, lnum)
    end,
  })
  setup_keymaps(bufnr, repo)
  setup_autocmds(bufnr)

  local lines = {}
  for i, section in ipairs(SECTIONS) do
    table.insert(lines, header(section))
    table.insert(lines, "Loading " .. LABELS[section]:lower() .. "...")
    if i < #SECTIONS then
      table.insert(lines, "")
    end
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
  for _, section in ipairs(SECTIONS) do
    module(section).attach(bufnr, repo)
  end
  return bufnr
end

--- Open the screen of `repo` (its existing buffer, with its pending edits, when there is one),
--- on `section` when given
function M.open(repo, section)
  local bufnr = screens[repo.id]
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    repo_of_buffer[bufnr] = repo
    vim.api.nvim_win_set_buf(0, bufnr)
  else
    bufnr = create(repo)
    vim.api.nvim_win_set_buf(0, bufnr)
    M.decorate(bufnr)
    for _, s in ipairs(SECTIONS) do
      module(s).reload(bufnr)
    end
  end
  if section then
    goto_section(bufnr, section)
  end
  return bufnr
end

--- The repository shown by `bufnr`, nil when it is not a repository screen
function M.repo_of(bufnr)
  return repo_of_buffer[bufnr]
end

M.notify = notify

-- Repository windows show the sections in their winbar; it is taken off again when the window
-- moves on to another buffer
vim.api.nvim_create_autocmd("BufWinEnter", {
  group = vim.api.nvim_create_augroup("workhorse_repo_winbar", { clear = true }),
  callback = function(args)
    local win = vim.api.nvim_get_current_win()
    if repo_of_buffer[args.buf] then
      vim.api.nvim_set_option_value("winbar", WINBAR, { scope = "local", win = win })
    elseif vim.wo[win].winbar == WINBAR then
      vim.api.nvim_set_option_value("winbar", "", { scope = "local", win = win })
    end
  end,
})

return M
