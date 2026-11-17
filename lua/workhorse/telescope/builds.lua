local M = {}

-- Pick a pipeline (build definition) using Telescope. The pipelines come from the repository
-- cache (workhorse.repos), or from opts.definitions when given (e.g. those of one repository),
-- without the hidden ones; opts.prompt_title replaces the title, opts.on_select(definition) what
-- picking one does (default: open its runs). The main pipeline of each repository has a star
-- (listed first when opts.definitions is given, so <leader>wb preselects it); <M-CR> makes the
-- selected pipeline the main one of its repository, or no longer main when it already is
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
  local repos = require("workhorse.repos")

  local function is_main(cache, def)
    return def.repository_id ~= nil and repos.main_of(cache, def.repository_id) == def.id
  end

  -- The pipelines with the main ones first when picking among those of one repository
  local function ordered(cache, definitions)
    if not opts.definitions then
      return definitions
    end
    local main, rest = {}, {}
    for _, def in ipairs(definitions) do
      table.insert(is_main(cache, def) and main or rest, def)
    end
    return vim.list_extend(main, rest)
  end

  local function make_finder(cache, definitions)
    return finders.new_table({
      results = ordered(cache, definitions),
      entry_maker = function(def)
        local folder = (def.path or "\\"):gsub("^\\", "")
        local label = folder ~= "" and (folder .. "\\" .. def.name) or def.name
        return {
          value = def,
          display = (is_main(cache, def) and "★ " or "  ") .. label,
          ordinal = label,
        }
      end,
    })
  end

  local function show(cache, definitions)
    if #definitions == 0 then
      vim.notify("Workhorse: No pipelines found", vim.log.levels.WARN)
      return
    end

    local picker_opts = vim.tbl_extend("force", {}, opts)
    picker_opts.definitions, picker_opts.prompt_title, picker_opts.on_select = nil, nil, nil
    pickers.new(picker_opts, {
      prompt_title = opts.prompt_title or "Azure DevOps Pipelines",
      finder = make_finder(cache, definitions),
      sorter = conf.generic_sorter(picker_opts),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection and opts.on_select then
            opts.on_select(selection.value)
          elseif selection then
            require("workhorse.builds").open_runs(selection.value.id, selection.value.name)
          end
        end)

        -- Star (or unstar) the selected pipeline as the main one of its repository
        local function toggle_main()
          local selection = action_state.get_selected_entry()
          if not selection then
            return
          end
          local def = selection.value
          if not def.repository_id then
            vim.notify("Workhorse: " .. def.name .. " is not built from a known repository", vim.log.levels.WARN)
            return
          end
          local main = not is_main(cache, def)
          repos.set_main(def, main, function(updated, err)
            if not updated then
              vim.notify("Workhorse: Could not set the main pipeline: " .. tostring(err or "unknown error"),
                vim.log.levels.ERROR)
              return
            end
            cache = updated
            local picker = action_state.get_current_picker(prompt_bufnr)
            if picker then
              picker:refresh(make_finder(cache, definitions), { reset_prompt = false })
            end
            vim.notify(main and ("Workhorse: ★ " .. def.name .. " is now the main pipeline of its repository")
              or ("Workhorse: " .. def.name .. " is no longer the main pipeline of its repository"))
          end)
        end
        map("i", "<M-CR>", toggle_main)
        map("n", "<M-CR>", toggle_main)
        return true
      end,
    }):find()
  end

  -- Hidden pipelines (hidden in the All tab of the pipelines screen) are left out
  repos.get(function(cache, err)
    if not cache then
      if opts.definitions then
        return show(nil, opts.definitions)
      end
      vim.notify("Workhorse: Failed to load pipelines: " .. tostring(err or "unknown error"), vim.log.levels.ERROR)
      return
    end
    show(cache, repos.visible(cache, opts.definitions))
  end)
end

return M
