local M = {}

-- In-memory storage for edited descriptions
-- { [work_item_id] = { description = "...", original = "...", modified = bool } }
local description_edits = {}

-- Track the description buffer and window
local desc_bufnr = nil
local desc_winid = nil
local current_item_id = nil

-- Convert HTML description to plain text (basic)
local function html_to_text(html)
  if not html or html == "" then
    return ""
  end
  -- Remove HTML tags (basic conversion)
  local text = html
  text = text:gsub("<br%s*/?>", "\n")
  text = text:gsub("<p>", "")
  text = text:gsub("</p>", "\n")
  text = text:gsub("<div>", "")
  text = text:gsub("</div>", "\n")
  text = text:gsub("<[^>]+>", "")
  -- Decode common HTML entities
  text = text:gsub("&nbsp;", " ")
  text = text:gsub("&lt;", "<")
  text = text:gsub("&gt;", ">")
  text = text:gsub("&amp;", "&")
  text = text:gsub("&quot;", '"')
  -- Trim trailing whitespace from lines
  text = text:gsub("[ \t]+\n", "\n")
  -- Remove excessive blank lines
  text = text:gsub("\n\n\n+", "\n\n")
  return vim.trim(text)
end

-- Convert plain text back to HTML for Azure DevOps
local function text_to_html(text)
  if not text or text == "" then
    return ""
  end
  -- Escape HTML entities
  text = text:gsub("&", "&amp;")
  text = text:gsub("<", "&lt;")
  text = text:gsub(">", "&gt;")
  -- Convert newlines to <br>
  text = text:gsub("\n", "<br>")
  return text
end

-- Save current buffer content to memory
local function save_to_memory()
  if not desc_bufnr or not vim.api.nvim_buf_is_valid(desc_bufnr) then
    return
  end
  if not current_item_id then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(desc_bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")

  local edit = description_edits[current_item_id]
  if edit then
    edit.description = content
    edit.modified = (content ~= edit.original)
  end
end

-- Get or create the description buffer
local function get_or_create_buffer()
  if desc_bufnr and vim.api.nvim_buf_is_valid(desc_bufnr) then
    return desc_bufnr
  end

  desc_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(desc_bufnr, "workhorse://description")
  vim.bo[desc_bufnr].buftype = "nofile"
  vim.bo[desc_bufnr].filetype = "markdown"
  vim.bo[desc_bufnr].swapfile = false
  vim.bo[desc_bufnr].bufhidden = "hide"

  -- Auto-save to memory when leaving buffer or on text change
  local group = vim.api.nvim_create_augroup("workhorse_description_" .. desc_bufnr, { clear = true })

  vim.api.nvim_create_autocmd({ "BufLeave", "BufHidden" }, {
    group = group,
    buffer = desc_bufnr,
    callback = save_to_memory,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = desc_bufnr,
    callback = function()
      -- Mark as modified in memory
      if current_item_id and description_edits[current_item_id] then
        local lines = vim.api.nvim_buf_get_lines(desc_bufnr, 0, -1, false)
        local content = table.concat(lines, "\n")
        description_edits[current_item_id].description = content
        description_edits[current_item_id].modified = (content ~= description_edits[current_item_id].original)
      end
    end,
  })

  return desc_bufnr
end

-- Open or focus the description window
local function open_or_focus_window()
  local bufnr = get_or_create_buffer()

  -- Check if window is still valid
  if desc_winid and vim.api.nvim_win_is_valid(desc_winid) then
    vim.api.nvim_set_current_win(desc_winid)
    return desc_winid
  end

  -- Open a vertical split on the right
  vim.cmd("vsplit")
  vim.cmd("wincmd L")
  desc_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(desc_winid, bufnr)

  -- Set window options
  vim.wo[desc_winid].wrap = true
  vim.wo[desc_winid].linebreak = true

  return desc_winid
end

-- Open description for a work item
function M.open(work_item)
  if not work_item then
    vim.notify("Workhorse: No work item provided", vim.log.levels.WARN)
    return
  end

  -- Save current content before switching
  save_to_memory()

  local item_id = work_item.id

  -- Initialize edit storage if needed
  if not description_edits[item_id] then
    local plain_text = html_to_text(work_item.description or "")
    description_edits[item_id] = {
      description = plain_text,
      original = plain_text,
      modified = false,
    }
  end

  -- Open/focus the window
  open_or_focus_window()

  -- Set current item
  current_item_id = item_id

  -- Load content
  local edit = description_edits[item_id]
  local lines = vim.split(edit.description, "\n", { plain = true })

  -- Update buffer content
  local bufnr = get_or_create_buffer()
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  -- Update buffer name to show which item
  vim.api.nvim_buf_set_name(bufnr, "workhorse://description/#" .. item_id)
end

-- Get all pending description changes
function M.get_pending_changes()
  local changes = {}
  for item_id, edit in pairs(description_edits) do
    if edit.modified then
      table.insert(changes, {
        id = item_id,
        description = text_to_html(edit.description),
      })
    end
  end
  return changes
end

-- Check if there are any pending description changes
function M.has_pending_changes()
  for _, edit in pairs(description_edits) do
    if edit.modified then
      return true
    end
  end
  return false
end

-- Mark a description as saved (after successful API call)
function M.mark_saved(item_id)
  if description_edits[item_id] then
    description_edits[item_id].original = description_edits[item_id].description
    description_edits[item_id].modified = false
  end
end

-- Clear all edits (e.g., after refresh)
function M.clear_edits()
  description_edits = {}
end

-- Update stored description from refreshed work item
function M.update_from_item(work_item)
  local item_id = work_item.id
  local edit = description_edits[item_id]

  if edit and not edit.modified then
    -- Not modified, update with new server value
    local plain_text = html_to_text(work_item.description or "")
    edit.description = plain_text
    edit.original = plain_text
  end
  -- If modified, keep the user's edits
end

return M
