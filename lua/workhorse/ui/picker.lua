-- Fuzzy picker of a list of items: Telescope when available, otherwise vim.ui.select (fuzzy with
-- snacks.nvim, fzf-lua or dressing). Used by the menu and the <M-/> searches of the screens
local M = {}

--- Pick one of `items`. opts.prompt: the title; opts.format_item(item): the text shown and matched.
--- `on_choice(item)` runs once the picker is closed (screens open in the window it came from), and
--- not at all when it is cancelled
function M.select(items, opts, on_choice)
  local format = opts.format_item or tostring
  local function run(item)
    if item then
      vim.schedule(function()
        on_choice(item)
      end)
    end
  end
  if not pcall(require, "telescope") then
    return vim.ui.select(items, { prompt = opts.prompt, format_item = format }, run)
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers.new({}, {
    prompt_title = opts.prompt,
    finder = finders.new_table({
      results = items,
      entry_maker = function(item)
        local text = format(item)
        return { value = item, display = text, ordinal = text }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        run(selection and selection.value)
      end)
      return true
    end,
  }):find()
end

return M
