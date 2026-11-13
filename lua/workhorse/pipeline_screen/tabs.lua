-- Tabs of the screen of one pipeline: Runs (its runs list, builds/init.lua), Settings
-- (pipeline_screen/settings.lua) and Variables (pipeline_screen/variables.lua). Each tab is its own
-- buffer, so the pending edits of Settings and Variables survive switching tabs; switching shows
-- the other buffer in the window. The tabs show in the winbar (clickable), like those of a pull
-- request; <Tab>/<S-Tab> (normal mode) cycle them and g1 g2 g3 jump to one.
local M = {}

local TABS = { "runs", "settings", "variables" }
local TAB_LABELS = { runs = "Runs", settings = "Settings", variables = "Variables" }
M.TABS = TABS
M.TAB_LABELS = TAB_LABELS

--- Tab shown by `bufnr`, the pipeline's id and its name; nil when it is not a pipeline tab
function M.tab_of(bufnr)
  local builds = package.loaded["workhorse.builds"]
  local ctx = builds and builds.runs_of(bufnr)
  if ctx then
    return "runs", ctx.definition_id, ctx.definition_name
  end
  local screen = package.loaded["workhorse.pipeline_screen"]
  local info = screen and screen.info(bufnr)
  if info then
    return info.tab, info.definition.id, info.definition.name
  end
end

--- Show `tab` of pipeline `definition_id` in the current window
function M.show(definition_id, name, tab)
  if tab == "runs" then
    return require("workhorse.builds").open_runs(definition_id, name)
  end
  return require("workhorse.pipeline_screen").open(definition_id, name, tab)
end

function M.winbar()
  local win = vim.g.statusline_winid or vim.api.nvim_get_current_win()
  local current, _, name = M.tab_of(vim.api.nvim_win_get_buf(win))
  if not current then
    return ""
  end
  local parts = {}
  for i, tab in ipairs(TABS) do
    local hl = tab == current and "%#WorkhorsePRTabSel#" or "%#WorkhorsePRTab#"
    table.insert(parts, "%" .. i .. "@v:lua.WorkhorsePipelineTabClick@" .. hl .. " " .. TAB_LABELS[tab] .. " %X")
  end
  return table.concat(parts, "%#WorkhorsePRTab#│") .. "%#WorkhorsePRTab#%=%#WorkhorseBuildMeta# "
    .. (name or ""):gsub("%%", "%%%%") .. " "
end

local WINBAR = "%{%v:lua.require'workhorse.pipeline_screen.tabs'.winbar()%}"

local function show_from(bufnr, tab)
  local _, id, name = M.tab_of(bufnr)
  if id then
    M.show(id, name, tab)
  end
end

function _G.WorkhorsePipelineTabClick(index)
  local win = vim.fn.getmousepos().winid
  if win and win ~= 0 and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    show_from(vim.api.nvim_win_get_buf(win), TABS[index])
  end
end

local function cycle(bufnr, step)
  local current = M.tab_of(bufnr)
  for i, tab in ipairs(TABS) do
    if tab == current then
      return show_from(bufnr, TABS[(i - 1 + step) % #TABS + 1])
    end
  end
end

--- Keymaps shared by the three tabs: switching tabs
function M.setup_buffer(bufnr)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, desc = "Workhorse: " .. desc })
  end
  map("<Tab>", function()
    cycle(bufnr, 1)
  end, "next pipeline tab")
  map("<S-Tab>", function()
    cycle(bufnr, -1)
  end, "previous pipeline tab")
  for i, tab in ipairs(TABS) do
    map("g" .. i, function()
      show_from(bufnr, tab)
    end, TAB_LABELS[tab] .. " tab of the pipeline")
  end
end

-- Pipeline windows show the tabs in their winbar; it is taken off again when the window moves on
-- to another buffer
vim.api.nvim_create_autocmd("BufWinEnter", {
  group = vim.api.nvim_create_augroup("workhorse_pipeline_winbar", { clear = true }),
  callback = function(args)
    local win = vim.api.nvim_get_current_win()
    if M.tab_of(args.buf) then
      vim.api.nvim_set_option_value("winbar", WINBAR, { scope = "local", win = win })
    elseif vim.wo[win].winbar == WINBAR then
      vim.api.nvim_set_option_value("winbar", "", { scope = "local", win = win })
    end
  end,
})

return M
