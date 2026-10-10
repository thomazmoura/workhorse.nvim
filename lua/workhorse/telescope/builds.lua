local M = {}

-- Pick a pipeline (build definition) using Telescope. The pipelines come from the repository
-- cache (workhorse.repos), or from opts.definitions when given (e.g. those of one repository);
-- opts.prompt_title replaces the title
function M.pick(opts)
  opts = opts or {}

  local ok, _ = pcall(require, "telescope")
  if not ok then
    vim.notify(
      "Workhorse: Telescope is required for the pipeline picker. Use :Workhorse builds <definitionId> instead.",
      vim.log.levels.WARN
    )
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local function show(definitions)
    if #definitions == 0 then
      vim.notify("Workhorse: No pipelines found", vim.log.levels.WARN)
      return
    end

    local picker_opts = vim.tbl_extend("force", {}, opts)
    picker_opts.definitions, picker_opts.prompt_title = nil, nil
    pickers.new(picker_opts, {
      prompt_title = opts.prompt_title or "Azure DevOps Pipelines",
      finder = finders.new_table({
        results = definitions,
        entry_maker = function(def)
          local folder = (def.path or "\\"):gsub("^\\", "")
          local label = folder ~= "" and (folder .. "\\" .. def.name) or def.name
          return {
            value = def,
            display = label,
            ordinal = label,
          }
        end,
      }),
      sorter = conf.generic_sorter(picker_opts),
      attach_mappings = function(prompt_bufnr, _)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then
            require("workhorse.builds").open_runs(selection.value.id, selection.value.name)
          end
        end)
        return true
      end,
    }):find()
  end

  if opts.definitions then
    show(opts.definitions)
    return
  end
  require("workhorse.repos").get(function(cache, err)
    if not cache then
      vim.notify("Workhorse: Failed to load pipelines: " .. tostring(err or "unknown error"), vim.log.levels.ERROR)
      return
    end
    show(cache.definitions)
  end)
end

return M
