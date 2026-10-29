-- Tabs of the pipelines screen: All (the editable tree, pipelines/init.lua) and Recent
-- (pipelines/recent.lua). Each tab is its own buffer, so the pending edits of the tree survive
-- switching tabs; switching shows the other buffer in the window. The tabs show in the winbar
-- (clickable), like those of a pull request.
local M = {}

local TABS = { "all", "recent" }
local TAB_LABELS = { recent = "Recent", all = "All" }

--- Tab shown by `bufnr`, nil when it is not a pipelines buffer
function M.tab_of(bufnr)
  if require("workhorse.pipelines.recent").is_recent_buffer(bufnr) then
    return "recent"
  end
  if require("workhorse.pipelines").is_pipelines_buffer(bufnr) then
    return "all"
  end
end

--- Show `tab` ("recent" or "all"; anything else is Recent) in the current window
function M.show(tab)
  if tab == "all" then
    return require("workhorse.pipelines").open_all()
  end
  return require("workhorse.pipelines.recent").open()
end

function M.winbar()
  local win = vim.g.statusline_winid or vim.api.nvim_get_current_win()
  local current = M.tab_of(vim.api.nvim_win_get_buf(win))
  if not current then
    return ""
  end
  local parts = {}
  for i, tab in ipairs(TABS) do
    local hl = tab == current and "%#WorkhorsePRTabSel#" or "%#WorkhorsePRTab#"
    table.insert(parts, "%" .. i .. "@v:lua.WorkhorsePipelinesTabClick@" .. hl .. " " .. TAB_LABELS[tab] .. " %X")
  end
  return table.concat(parts, "%#WorkhorsePRTab#│") .. "%#WorkhorsePRTab#%=%#WorkhorseBuildMeta# Pipelines "
end

local WINBAR = "%{%v:lua.require'workhorse.pipelines.tabs'.winbar()%}"

function _G.WorkhorsePipelinesTabClick(index)
  local win = vim.fn.getmousepos().winid
  if win and win ~= 0 and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    M.show(TABS[index])
  end
end

local function cycle(bufnr, step)
  for i, tab in ipairs(TABS) do
    if tab == M.tab_of(bufnr) then
      return M.show(TABS[(i - 1 + step) % #TABS + 1])
    end
  end
end

--- Keymaps shared by both tabs: switching tabs
function M.setup_buffer(bufnr)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, desc = "Workhorse: " .. desc })
  end
  map("<Tab>", function()
    cycle(bufnr, 1)
  end, "next pipelines tab")
  map("<S-Tab>", function()
    cycle(bufnr, -1)
  end, "previous pipelines tab")
  for i, tab in ipairs(TABS) do
    map("g" .. i, function()
      M.show(tab)
    end, TAB_LABELS[tab] .. " pipelines tab")
  end
  map("<M-/>", function()
    require("workhorse.builds").pick()
  end, "fuzzy search of the pipelines")
end

-- Pipelines windows show the tabs in their winbar; it is taken off again when the window moves on
-- to another buffer
vim.api.nvim_create_autocmd("BufWinEnter", {
  group = vim.api.nvim_create_augroup("workhorse_pipelines_winbar", { clear = true }),
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
