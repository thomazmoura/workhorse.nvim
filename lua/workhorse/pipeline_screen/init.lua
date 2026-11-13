-- The editable tabs of the screen of one pipeline (its Runs tab is the runs list of
-- builds/init.lua; the tabs are pipeline_screen/tabs.lua): Settings and Variables. Each one is an
-- editable buffer styled like the repository and library screens, the pipeline's name as its
-- title (<CR> on it goes to the Runs tab) and the tab's lines under it:
--
--   MyApp-CI                                   \Infra · pipelines/ci.yml
--   ───── ◇ ─────           (a virtual line: never in the text; frozen while scrolling)
--   Name: MyApp-CI          (pipeline_screen/settings.lua, or the variables of
--   ...                      pipeline_screen/variables.lua)
--
-- The tab modules read and render the lines below the title (M.content_lines, M.set_content),
-- with buffer line numbers. Saving (<leader><leader>) lists the changes of the tab, then applies
-- them. Both tabs share one definition table per pipeline (from get_definition_full), updated in
-- place when either loads or saves.
local M = {}

local pinned = require("workhorse.ui.pinned")
local choices = require("workhorse.ui.choices")

local MODULES = {
  settings = "workhorse.pipeline_screen.settings",
  variables = "workhorse.pipeline_screen.variables",
}

local ns = vim.api.nvim_create_namespace("workhorse_pipeline_screen")
-- The rule under the title, drawn apart so a resize redraws it alone
local rules_ns = vim.api.nvim_create_namespace("workhorse_pipeline_screen_rule")

-- [definition id] = the shared definition table
local definitions = {}
-- ["<definition id>:<tab>"] = bufnr
local screens = {}
-- [bufnr] = { definition, tab }
local infos = {}

local function notify(msg, level)
  vim.notify("Workhorse: " .. msg, level or vim.log.levels.INFO)
end
M.notify = notify

local function module(bufnr)
  return require(MODULES[infos[bufnr].tab])
end

--- { definition, tab } of the pipeline tab `bufnr`, nil for any other buffer
function M.info(bufnr)
  return infos[bufnr or vim.api.nvim_get_current_buf()]
end

-- Title -------------------------------------------------------------------------

-- Line 1 is the title unless it was deleted (a blank line or a "key: value" line took its place)
local function is_title(bufnr, lnum)
  if lnum ~= 1 then
    return false
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
  local info = infos[bufnr]
  return (info and line == info.definition.name) or (not line:match("^%s*$") and not line:find(":", 1, true))
end

-- Put the title line back when it was deleted or edited (or the pipeline renamed)
local function ensure_title(bufnr)
  local text = infos[bufnr].definition.name
  local first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
  if first == text then
    return
  end
  if is_title(bufnr, 1) then
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { text })
  else
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { text })
  end
end

--- Lines of the tab (below the title) and the buffer line number before the first one (line i of
--- the result is buffer line offset + i)
function M.content_lines(bufnr)
  local offset = is_title(bufnr, 1) and 1 or 0
  return vim.api.nvim_buf_get_lines(bufnr, offset, -1, false), offset
end

--- Replace the lines of the tab (below the title, put back when it is gone)
function M.set_content(bufnr, lines)
  ensure_title(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 1, -1, false, #lines > 0 and lines or { "" })
end

--- After the tab was re-rendered: the buffer is modified when it still has changes
function M.update_modified(bufnr)
  if infos[bufnr] then
    vim.bo[bufnr].modified = module(bufnr).pending(bufnr)
  end
end

local function window_width(bufnr)
  local win = vim.fn.win_findbuf(bufnr)[1]
  local width = win and vim.api.nvim_win_get_width(win) or vim.o.columns
  if win then
    width = width - vim.fn.getwininfo(win)[1].textoff
  end
  return width
end

local function draw_rule(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, rules_ns, 0, -1)
  if is_title(bufnr, 1) then
    vim.api.nvim_buf_set_extmark(bufnr, rules_ns, 0, 0,
      { virt_lines = { require("workhorse.ui.header").rule(window_width(bufnr)) } })
  end
  -- The title and the rule under it stay frozen at the top while scrolling
  pinned.schedule_refresh(bufnr)
end

-- Right side of the title: the folder, the YAML file (or classic) and the repository
local function title_meta(definition)
  local parts = {}
  if definition.path and definition.path ~= "\\" then
    table.insert(parts, definition.path)
  end
  if definition.loaded then
    table.insert(parts, definition.yaml_file or "classic pipeline")
    local repo = definition.repository
    if repo and repo.name then
      table.insert(parts, repo.name)
    end
  end
  return table.concat(parts, " · ")
end

--- Highlights and hints of the whole buffer
function M.decorate(bufnr)
  local info = infos[bufnr]
  if not info then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if is_title(bufnr, 1) then
    local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
    vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, { end_col = #line, hl_group = "WorkhorseBuildHeader" })
    vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
      virt_text = { { title_meta(info.definition), "WorkhorseBuildMeta" } },
      virt_text_pos = "right_align",
    })
  end
  draw_rule(bufnr)
  module(bufnr).decorate(bufnr)
end

--- Hint at the end of buffer line `lnum` (e.g. why the tab is empty), drawn by the tab's decorate
function M.line_hint(bufnr, lnum, text, hl)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, 0,
    { virt_text = { { "  " .. text, hl or "WorkhorseRunHint" } } })
end

-- Definition --------------------------------------------------------------------

--- The definition shared by the tabs of pipeline `id`, `fresh` (from get_definition_full) copied
--- into it in place; the titles of its open tabs follow a rename
function M.update_definition(id, fresh)
  local current = definitions[id]
  if not current then
    current = {}
    definitions[id] = current
  end
  if current ~= fresh then
    for k in pairs(current) do
      current[k] = nil
    end
    for k, v in pairs(fresh) do
      current[k] = v
    end
  end
  current.loaded = true
  for bufnr, info in pairs(infos) do
    if info.definition == current and vim.api.nvim_buf_is_valid(bufnr) then
      ensure_title(bufnr)
      M.decorate(bufnr)
    end
  end
  return current
end

--- After a save renamed or moved pipeline `definition`: its runs list, the repository cache and
--- the last opened pipeline (:Workhorse resume-build) follow
function M.renamed(definition)
  require("workhorse.builds").set_definition_name(definition.id, definition.name)
  local repo = definition.repository or {}
  require("workhorse.repos").learn_definitions({ {
    id = definition.id,
    name = definition.name,
    path = definition.path,
    repository_id = repo.type == "TfsGit" and repo.id or nil,
  } })
  local session = require("workhorse.session")
  local last = session.get_last_build()
  if last and tonumber(last.id) == tonumber(definition.id) then
    session.save_last_build(definition.id, definition.name)
  end
end

-- Save and refresh --------------------------------------------------------------

--- List the changes of the tab `bufnr`, then apply them
function M.save(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local info = infos[bufnr]
  if not info then
    return
  end
  local result, err = module(bufnr).prepare(bufnr)
  if err then
    notify(err, vim.log.levels.WARN)
    return
  end
  if not result or #result.entries == 0 then
    vim.bo[bufnr].modified = false
    notify("No changes to apply")
    return
  end
  local title = ("Changes to the %s of %s"):format(info.tab, info.definition.name)
  require("workhorse.ui.list_confirm").show(title, result.entries, function(confirmed)
    if confirmed then
      result.apply(function() end)
    end
  end)
end

--- Reload the pipeline tab `bufnr` (default: current), asking first when there are unsaved
--- changes; false when it is not one
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not infos[bufnr] then
    return false
  end
  if module(bufnr).saving(bufnr) then
    notify("Wait for the save to finish", vim.log.levels.WARN)
    return true
  end
  if vim.bo[bufnr].modified and vim.fn.confirm("Discard the pending changes and reload?", "&Discard\n&Cancel", 2) ~= 1 then
    return true
  end
  ensure_title(bufnr)
  module(bufnr).reload(bufnr)
  return true
end

-- Buffer ------------------------------------------------------------------------

-- Lines holding a value ("key: value"), in order
local function value_lines(bufnr)
  local result = {}
  for lnum, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if not is_title(bufnr, lnum) and line:match("^%s*[^%s:][^:]*:") then
      table.insert(result, lnum)
    end
  end
  return result
end

--- Move the cursor to the start of the next (dir = 1) or previous (dir = -1) value
function M.jump_value(dir)
  require("workhorse.builds.form").jump(dir, value_lines(vim.api.nvim_get_current_buf()), { at_start = true })
end

local function go_runs(bufnr)
  local definition = infos[bufnr].definition
  require("workhorse.builds").open_runs(definition.id, definition.name)
end

local function setup_keymaps(bufnr)
  local definition = infos[bufnr].definition
  local function map(lhs, fn, desc, mode)
    vim.keymap.set(mode or "n", lhs, fn, { buffer = bufnr, silent = true, desc = "Workhorse: " .. desc })
  end
  require("workhorse.ui.send").map(bufnr, function()
    M.save(bufnr)
  end, "apply the changes")
  map("<leader>R", function()
    M.refresh(bufnr)
  end, "reload the pipeline tab")
  -- <CR> goes to the Runs tab on the title; elsewhere it moves down as usual
  map("<CR>", function()
    local count = vim.v.count1
    if is_title(bufnr, vim.api.nvim_win_get_cursor(0)[1]) then
      return go_runs(bufnr)
    end
    vim.cmd("normal! " .. count .. "+")
  end, "runs of the pipeline (on the title)")
  map("-", function()
    go_runs(bufnr)
  end, "runs of the pipeline")
  local builds = require("workhorse.builds")
  local function open_web()
    builds.open_url(builds.definition_url(definition.id))
  end
  map("gw", open_web, "open the pipeline in the browser")
  map("gb", open_web, "open the pipeline in the browser")
  builds.map_yank(bufnr, open_web, "the pipeline")
  map("<M-/>", function()
    builds.pick()
  end, "fuzzy search of the pipelines")
  -- Insert mode: move in an open completion menu, jump to the next value otherwise
  for dir, lhs in pairs({ [1] = "<Tab>", [-1] = "<S-Tab>" }) do
    vim.keymap.set("i", lhs, function()
      return require("workhorse.builds.form").menu_key(dir)
        or ("<Cmd>lua require('workhorse.pipeline_screen').jump_value(%d)<CR>"):format(dir)
    end, { buffer = bufnr, silent = true, expr = true, desc = "Workhorse: " .. (dir > 0 and "next" or "previous") .. " value" })
  end
  -- Accept a completion with <CR>; a plain new line otherwise
  vim.keymap.set("i", "<CR>", choices.insert_cr, { buffer = bufnr, silent = true, expr = true,
    desc = "Workhorse: accept the completion" })
  -- Normal <Tab>/<S-Tab>, g1 g2 g3: the tabs
  require("workhorse.pipeline_screen.tabs").setup_buffer(bufnr)
end

local function setup_autocmds(bufnr)
  local group = vim.api.nvim_create_augroup("workhorse_pipeline_screen_" .. bufnr, { clear = true })
  -- :w does not send (an auto-save plugin must not apply anything): <leader><leader> does
  require("workhorse.ui.send").ignore_write(bufnr, group)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      local m = module(bufnr)
      if m.on_change then
        m.on_change(bufnr)
      end
      M.decorate(bufnr)
    end,
  })
  -- The rule spans the window
  vim.api.nvim_create_autocmd({ "BufWinEnter", "VimResized", "WinResized" }, {
    group = group,
    callback = function()
      if vim.api.nvim_buf_is_valid(bufnr) and #vim.fn.win_findbuf(bufnr) > 0 then
        draw_rule(bufnr)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
      local info = infos[bufnr]
      infos[bufnr] = nil
      if info then
        local key = info.definition.id .. ":" .. info.tab
        if screens[key] == bufnr then
          screens[key] = nil
        end
      end
    end,
  })
end

local function create(definition, tab)
  local bufnr = vim.api.nvim_create_buf(true, false)
  local label = definition.name:gsub("[%s/\\|]+", "_")
  if not pcall(vim.api.nvim_buf_set_name, bufnr, "Workhorse|pipeline|" .. label .. "|" .. tab) then
    pcall(vim.api.nvim_buf_set_name, bufnr, "Workhorse|pipeline|" .. definition.id .. "|" .. tab)
  end
  -- acwrite: :w does nothing (BufWriteCmd) instead of writing a file
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "workhorse-pipeline"
  infos[bufnr] = { definition = definition, tab = tab }
  screens[definition.id .. ":" .. tab] = bufnr
  choices.attach(bufnr, {
    choices = function(b, lnum)
      if is_title(b, lnum) then
        return nil
      end
      return module(b).choices(b, lnum)
    end,
    start = function(line, lnum)
      if is_title(bufnr, lnum) then
        return nil
      end
      return module(bufnr).start(line, lnum)
    end,
  })
  setup_keymaps(bufnr)
  setup_autocmds(bufnr)
  pinned.attach(bufnr, function()
    return is_title(bufnr, 1) and 1 or 0
  end)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { definition.name, "Loading " .. tab .. "..." })
  vim.bo[bufnr].modified = false
  module(bufnr).attach(bufnr, definition)
  return bufnr
end

--- Open `tab` ("settings" or "variables") of pipeline `id` (its existing buffer, with its pending
--- edits, when there is one)
function M.open(id, name, tab)
  id = tonumber(id) or id
  local definition = definitions[id]
  if not definition then
    definition = { id = id, name = name or ("Pipeline " .. id), path = "\\" }
    definitions[id] = definition
  end
  local bufnr = screens[id .. ":" .. tab]
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_win_set_buf(0, bufnr)
    ensure_title(bufnr)
    M.decorate(bufnr)
    return bufnr
  end
  bufnr = create(definition, tab)
  vim.api.nvim_win_set_buf(0, bufnr)
  M.decorate(bufnr)
  module(bufnr).reload(bufnr)
  return bufnr
end

return M
