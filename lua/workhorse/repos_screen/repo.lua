-- Screen of one repository, opened by <CR> on the repositories list (or <leader>wg for the
-- repository of the working directory): one editable buffer styled like the pull request
-- screen, a "name" title (<CR> on it goes back to the list) and three sections, each under its
-- title line with its lines indented one level:
--
--   my-repo
--   ───── ◇ ─────           (virtual lines: never in the text)
--
--   General                 (repos_screen/general.lua)
--     Default branch: main
--
--   ───── ◇ ─────
--
--   Security                (repos_screen/security.lua)
--     ...
--   Policies                (repos_screen/policies.lua)
--     ...
--
-- Each section module only reads and renders the lines of its own section (M.section_lines,
-- M.set_section), with buffer line numbers; the section's indent is taken off the lines it reads
-- and put back on the lines it writes, so a module sees its top level at level 0. Saving confirms
-- the changes of every section in one list, then applies them. { and } move between the
-- sections; the winbar names them (clickable).
local M = {}

local fold = require("workhorse.fold")
local guides = require("workhorse.buffer_tree.guides")
local choices = require("workhorse.ui.choices")
local parse_indent = require("workhorse.buffer_tree.parser").parse_indent

local SECTIONS = { "general", "security", "policies" }
local LABELS = { general = "General", security = "Security", policies = "Policies" }
local MODULES = {
  general = "workhorse.repos_screen.general",
  security = "workhorse.repos_screen.security",
  policies = "workhorse.repos_screen.policies",
}
-- Page of the repository settings in the web UI (?_a=) of each section
local WEB_PAGES = { general = "settings", security = "permissions", policies = "policies" }
local SECTION_OF_LABEL = {}
for _, section in ipairs(SECTIONS) do
  SECTION_OF_LABEL[LABELS[section]:lower()] = section
end

local ns = vim.api.nvim_create_namespace("workhorse_repo_headers")
-- Separators, drawn apart so a resize redraws them alone
local rules_ns = vim.api.nvim_create_namespace("workhorse_repo_rules")

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
  return LABELS[section]
end

--- Section named by a header line (its title, unindented), nil for any other line
function M.parse_header(line)
  local label = (line or ""):match("^(%a+)%s*$")
  return label and SECTION_OF_LABEL[label:lower()]
end

-- Section named by buffer line `lnum`, never the title (a repository may be named "Security")
local function header_at(lnum, line)
  return lnum > 1 and M.parse_header(line) or nil
end

-- The title line (the repository name), always the first one
local function title(repo)
  return repo.name
end

-- Line 1 is the title unless it was deleted (a blank line or a section header took its place)
local function is_title(bufnr, lnum)
  if lnum ~= 1 then
    return false
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
  local repo = repo_of_buffer[bufnr]
  return (repo and line == title(repo)) or (not line:match("^%s*$") and not M.parse_header(line))
end

--- `line` without the indent of its section (one level), as the section modules read it
function M.dedent(line)
  local width = guides.width()
  return line:sub(math.min(#line:match("^ *"), width) + 1)
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

--- Lines of `section`, without its indent (see M.dedent), and the buffer line number before its
--- first one (line i of the result is buffer line offset + i); nil when its header is gone
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
    if l == lnum then
      break
    end
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

local function window_width(bufnr)
  local win = vim.fn.win_findbuf(bufnr)[1]
  local width = win and vim.api.nvim_win_get_width(win) or vim.o.columns
  if win then
    width = width - vim.fn.getwininfo(win)[1].textoff
  end
  return width
end

-- The separators, as the pull request screen draws them ("───── ◇ ─────" across the window):
-- under the title, and above every section title but the first one (after its blank line)
local function draw_rules(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, rules_ns, 0, -1)
  local width = window_width(bufnr)
  local side = math.max(math.floor((width - 3) / 2), 1)
  local rule = {
    { string.rep("─", side), "WorkhorseBuildSeparator" },
    { " ◇ ", "WorkhorseBuildSeparator" },
    { string.rep("─", math.max(width - 3 - side, 1)), "WorkhorseBuildSeparator" },
  }
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
end

-- Size of a repository ("37.6 MB")
local function size_text(bytes)
  if not bytes then
    return nil
  end
  local units = { "B", "KB", "MB", "GB" }
  local i = 1
  while bytes >= 1024 and i < #units do
    bytes = bytes / 1024
    i = i + 1
  end
  return i == 1 and (bytes .. " B") or ("%.1f %s"):format(bytes, units[i])
end

--- Highlights and hints of the whole buffer
function M.decorate(bufnr)
  local repo = repo_of_buffer[bufnr]
  if not repo then
    return
  end
  guides.draw(bufnr, { boundary = M.parse_header })
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if is_title(bufnr, 1) then
    local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
    local meta = {}
    for _, part in ipairs({ repo.project and repo.project.name or false, size_text(repo.size) or false,
      repo.disabled and "disabled" or false }) do
      if part then
        table.insert(meta, part)
      end
    end
    vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, { end_col = #line, hl_group = "WorkhorseBuildHeader" })
    vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
      virt_text = { { table.concat(meta, " · "), repo.disabled and "WorkhorseRepoDisabled"
        or "WorkhorseBuildMeta" } },
      virt_text_pos = "right_align",
    })
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
    if lnum > 1 and not M.parse_header(line) and line:match("^%s*[^%s:][^:]*:") then
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
    or config.project), repo.id, WEB_PAGES[section] or WEB_PAGES[SECTIONS[1]])
end

-- Clone URLs of `repo`: the ones the server reports, or else built from server_url
local function clone_urls(repo)
  local config = require("workhorse.config").get()
  local server = (config.server_url or ""):gsub("/$", "")
  local path = ("/%s/_git/%s"):format(repo.project and repo.project.name or config.project, repo.name)
  return {
    https = repo.remote_url or (server .. path),
    ssh = repo.ssh_url or (server:gsub("^https?://([^/]+)", "ssh://%1:22") .. path),
  }
end

local function push_script(url)
  return ("git remote add origin %s;\ngit push -u origin --all"):format(url)
end

-- The screen's repository table is shared with its sections: it is updated in place
local function set_repo(bufnr, repo)
  local current = repo_of_buffer[bufnr]
  if not current then
    repo_of_buffer[bufnr] = repo
    return
  end
  if current ~= repo then
    for k in pairs(current) do
      current[k] = nil
    end
    for k, v in pairs(repo) do
      current[k] = v
    end
  end
end

-- Runs `script` in a terminal split, in Neovim's working directory, so its output shows and
-- credential prompts (SSH passphrase, HTTPS login) can be answered. Once it succeeds, the
-- repository (its default branch, set by a first push) and the screen of `bufnr` are reloaded
local function run_script(bufnr, script)
  local cwd = vim.fn.getcwd()
  if vim.fn.confirm(("Run in %s?\n\n%s"):format(cwd, script), "&Run\n&Cancel", 2) ~= 1 then
    return
  end
  vim.cmd("botright 12split")
  vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(false, true))
  vim.fn.jobstart({ vim.o.shell, vim.o.shellcmdflag, script }, {
    term = true,
    cwd = cwd,
    on_exit = function(_, code)
      local repo = repo_of_buffer[bufnr]
      if code ~= 0 or not repo then
        return
      end
      require("workhorse.api.repositories").get(repo.id, function(fresh, err)
        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        if fresh then
          set_repo(bufnr, fresh)
        else
          notify("Failed to reload the repository: " .. tostring(err), vim.log.levels.WARN)
        end
        M.refresh(bufnr)
      end)
    end,
  })
end

local function copy(text)
  if not pcall(vim.fn.setreg, "+", text) then
    notify("no clipboard available", vim.log.levels.ERROR)
    return
  end
  notify("copied: " .. text:gsub("\n", " "))
end

--- Menu of the repository's options (<leader>wo): copying its clone URLs and push scripts to
--- the clipboard, or running a push script
function M.options_menu(bufnr)
  local repo = repo_of_buffer[bufnr]
  local urls = clone_urls(repo)
  local options = {
    { label = "Copy the SSH URL", text = urls.ssh },
    { label = "Copy the HTTPS URL", text = urls.https },
    { label = "Copy the push script (SSH)", text = push_script(urls.ssh) },
    { label = "Copy the push script (HTTPS)", text = push_script(urls.https) },
    { label = "Run the push script (SSH)", text = push_script(urls.ssh), run = true },
    { label = "Run the push script (HTTPS)", text = push_script(urls.https), run = true },
  }
  vim.ui.select(options, {
    prompt = repo.name .. ":",
    format_item = function(option)
      return option.label
    end,
  }, function(option)
    if option then
      if option.run then
        run_script(bufnr, option.text)
      else
        copy(option.text)
      end
    end
  end)
end

-- Completion and folds go to the module of the line's section
local function in_section(bufnr, lnum, fn)
  local section = M.section_at(bufnr, lnum)
  if section and not header_at(lnum, vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]) then
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

-- Put the title line back when it was deleted or edited (or the repository renamed)
local function ensure_title(bufnr)
  local text = title(repo_of_buffer[bufnr])
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
  ensure_title(bufnr)
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
  for _, lhs in ipairs(require("workhorse.config").space_keys()) do
    map(lhs, function()
      fold.toggle(bufnr)
    end, "fold or unfold")
  end
  -- <CR> goes back to the list on the title, folds like <Space> on a line with a fold; elsewhere
  -- it moves down as usual
  map("<CR>", function()
    local count = vim.v.count1
    if is_title(bufnr, vim.api.nvim_win_get_cursor(0)[1]) then
      require("workhorse.repos_screen").open()
      return
    end
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
  map("gb", function()
    vim.ui.open(require("workhorse.api.pullrequests").repo_url(repo))
  end, "open the repository in the browser")
  map("<leader>wo", function()
    M.options_menu(bufnr)
  end, "repository options (clone URLs and push scripts)")
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
        local found = header_at(lnum, line)
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
      if header_at(lnum, line) then
        return nil
      end
      local section = M.section_at(bufnr, lnum)
      return section and module(section).start(line, lnum)
    end,
  })
  setup_keymaps(bufnr, repo)
  setup_autocmds(bufnr)

  local lines = { title(repo), "" }
  for i, section in ipairs(SECTIONS) do
    table.insert(lines, header(section))
    table.insert(lines, guides.prefix(1) .. "Loading " .. LABELS[section]:lower() .. "...")
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
    set_repo(bufnr, repo)
    vim.api.nvim_win_set_buf(0, bufnr)
    ensure_title(bufnr)
    M.decorate(bufnr)
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
