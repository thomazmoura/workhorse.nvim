local M = {}

-- In-memory storage for edited descriptions and tags
-- { [work_item_id] = { description = "...", original = "...", modified = bool } }
local description_edits = {}
-- { [work_item_id] = { tags = [...], original = [...], modified = bool } }
local tags_edits = {}

-- Track buffers and windows
local desc_bufnr = nil
local desc_winid = nil
local tags_bufnr = nil
local tags_winid = nil
local current_item_id = nil
local closing_in_progress = false

-- Header constants
local DESC_HEADER = "═══ Description ═══"
local TAGS_HEADER = "═══ Tags ═══"

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

-- Parse tags from semicolon-separated string to array
local function parse_tags(tags_string)
  local tags = {}
  if not tags_string or tags_string == "" then
    return tags
  end
  for tag in tags_string:gmatch("[^;]+") do
    local trimmed = vim.trim(tag)
    if trimmed ~= "" then
      table.insert(tags, trimmed)
    end
  end
  return tags
end

-- Save description buffer content to memory
local function save_description_to_memory()
  if not desc_bufnr or not vim.api.nvim_buf_is_valid(desc_bufnr) then
    return
  end
  if not current_item_id then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(desc_bufnr, 0, -1, false)
  -- Skip header line
  if #lines > 0 and lines[1] == DESC_HEADER then
    table.remove(lines, 1)
  end
  -- Skip leading empty lines (we add one after header)
  while #lines > 0 and vim.trim(lines[1]) == "" do
    table.remove(lines, 1)
  end
  -- Skip trailing empty lines
  while #lines > 0 and vim.trim(lines[#lines]) == "" do
    table.remove(lines)
  end
  local content = table.concat(lines, "\n")

  local edit = description_edits[current_item_id]
  if edit then
    edit.description = content
    edit.modified = (content ~= edit.original)
  end
end

-- Save tags buffer content to memory
local function save_tags_to_memory()
  if not tags_bufnr or not vim.api.nvim_buf_is_valid(tags_bufnr) then
    return
  end
  if not current_item_id then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(tags_bufnr, 0, -1, false)
  -- Skip header line
  if #lines > 0 and lines[1] == TAGS_HEADER then
    table.remove(lines, 1)
  end
  -- Filter out empty lines and trim
  local tags = {}
  for _, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    if trimmed ~= "" then
      table.insert(tags, trimmed)
    end
  end

  local edit = tags_edits[current_item_id]
  if edit then
    edit.tags = tags
    -- Compare arrays
    local same = #tags == #edit.original
    if same then
      for i, tag in ipairs(tags) do
        if tag ~= edit.original[i] then
          same = false
          break
        end
      end
    end
    edit.modified = not same
  end
end

-- Protect header from being deleted (restore if needed)
local function setup_header_protection(bufnr, header_text, save_fn)
  local group = vim.api.nvim_create_augroup("workhorse_header_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      local first_line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
      if first_line ~= header_text then
        -- Restore header
        vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { header_text })
      end
      -- Save to memory
      save_fn()
      -- Keep buffer unmodified so it doesn't block navigation
      vim.bo[bufnr].modified = false
    end,
  })

  vim.api.nvim_create_autocmd({ "BufLeave", "BufHidden" }, {
    group = group,
    buffer = bufnr,
    callback = save_fn,
  })
end

-- Delete any existing buffer matching the given pattern
local function delete_buffers_matching(pattern)
  local bufs = vim.api.nvim_list_bufs()
  for _, buf in ipairs(bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      local buf_name = vim.api.nvim_buf_get_name(buf)
      if buf_name:match(pattern) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end
end

-- Get or create the description buffer
local function get_or_create_description_buffer()
  if desc_bufnr and vim.api.nvim_buf_is_valid(desc_bufnr) then
    return desc_bufnr
  end

  -- Clean up any orphaned buffer with this name
  delete_buffers_matching("workhorse://description")

  desc_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(desc_bufnr, "workhorse://description")
  vim.bo[desc_bufnr].buftype = "nofile"
  vim.bo[desc_bufnr].filetype = "markdown"
  vim.bo[desc_bufnr].swapfile = false
  vim.bo[desc_bufnr].bufhidden = "hide"

  setup_header_protection(desc_bufnr, DESC_HEADER, save_description_to_memory)

  return desc_bufnr
end

-- Get or create the tags buffer
local function get_or_create_tags_buffer()
  if tags_bufnr and vim.api.nvim_buf_is_valid(tags_bufnr) then
    return tags_bufnr
  end

  -- Clean up any orphaned buffer with this name
  delete_buffers_matching("workhorse://tags")

  tags_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(tags_bufnr, "workhorse://tags")
  vim.bo[tags_bufnr].buftype = "nofile"
  vim.bo[tags_bufnr].filetype = ""
  vim.bo[tags_bufnr].swapfile = false
  vim.bo[tags_bufnr].bufhidden = "hide"

  setup_header_protection(tags_bufnr, TAGS_HEADER, save_tags_to_memory)

  return tags_bufnr
end

-- Close both windows
local function close_windows()
  -- Guard against re-entrant calls (from WinClosed autocommand)
  if closing_in_progress then
    return
  end
  closing_in_progress = true

  -- Clear the WinClosed autocommand to prevent callbacks during close
  vim.api.nvim_create_augroup("workhorse_side_panels", { clear = true })

  save_description_to_memory()
  save_tags_to_memory()

  -- Capture IDs before any close (closing one may affect the other's validity)
  local tags_win = tags_winid
  local desc_win = desc_winid
  local tags_buf = tags_bufnr
  local desc_buf = desc_bufnr

  -- Clear module state first
  tags_winid = nil
  desc_winid = nil
  desc_bufnr = nil
  tags_bufnr = nil

  -- Close windows
  if tags_win and vim.api.nvim_win_is_valid(tags_win) then
    vim.api.nvim_win_close(tags_win, true)
  end

  if desc_win and vim.api.nvim_win_is_valid(desc_win) then
    vim.api.nvim_win_close(desc_win, true)
  end

  -- Delete buffers to free up the names
  if tags_buf and vim.api.nvim_buf_is_valid(tags_buf) then
    vim.api.nvim_buf_delete(tags_buf, { force = true })
  end

  if desc_buf and vim.api.nvim_buf_is_valid(desc_buf) then
    vim.api.nvim_buf_delete(desc_buf, { force = true })
  end

  closing_in_progress = false
end

-- Check if panels are showing a specific item
local function is_showing_item(item_id)
  return desc_winid
    and vim.api.nvim_win_is_valid(desc_winid)
    and current_item_id == item_id
end

-- Open or focus the side panel windows
local function open_or_focus_windows()
  -- Check if windows are still valid - if so, just focus
  if desc_winid and vim.api.nvim_win_is_valid(desc_winid) and tags_winid and vim.api.nvim_win_is_valid(tags_winid) then
    vim.api.nvim_set_current_win(desc_winid)
    return
  end

  -- Close any stale windows (this also deletes buffers)
  close_windows()

  -- Create fresh buffers AFTER cleanup
  local desc_buf = get_or_create_description_buffer()
  local tags_buf = get_or_create_tags_buffer()

  -- Open a vertical split on the right for description
  vim.cmd("vsplit")
  vim.cmd("wincmd L")
  desc_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(desc_winid, desc_buf)

  -- Set description window options
  vim.wo[desc_winid].wrap = true
  vim.wo[desc_winid].linebreak = true

  -- Open a horizontal split below for tags
  vim.cmd("split")
  vim.cmd("wincmd j")
  tags_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(tags_winid, tags_buf)

  -- Set tags window options
  vim.wo[tags_winid].wrap = false

  -- Make tags window smaller (about 1/3 of right panel)
  vim.api.nvim_win_set_height(tags_winid, 10)

  -- Return focus to description window
  vim.api.nvim_set_current_win(desc_winid)

  -- Setup WinClosed autocommand to close both panels when one is manually closed
  local group = vim.api.nvim_create_augroup("workhorse_side_panels", { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      local closed_win = tonumber(args.match)
      if closed_win == desc_winid or closed_win == tags_winid then
        -- Defer to avoid issues during window close event
        vim.schedule(function()
          close_windows()
        end)
      end
    end,
  })
end

-- Open side panels for a work item (toggle if same item)
function M.open(work_item)
  if not work_item then
    vim.notify("Workhorse: No work item provided", vim.log.levels.WARN)
    return
  end

  local item_id = work_item.id

  -- Toggle: if already showing this item, close the windows
  if is_showing_item(item_id) then
    close_windows()
    return
  end

  -- Save current content before switching
  save_description_to_memory()
  save_tags_to_memory()

  -- Initialize description edit storage if needed
  if not description_edits[item_id] then
    local plain_text = html_to_text(work_item.description or "")
    description_edits[item_id] = {
      description = plain_text,
      original = plain_text,
      modified = false,
    }
  end

  -- Initialize tags edit storage if needed
  if not tags_edits[item_id] then
    local tags_array = parse_tags(work_item.tags or "")
    tags_edits[item_id] = {
      tags = vim.deepcopy(tags_array),
      original = vim.deepcopy(tags_array),
      modified = false,
    }
  end

  -- Open/focus the windows
  open_or_focus_windows()

  -- Set current item
  current_item_id = item_id

  -- Load description content (add empty line only if no content)
  local desc_edit = description_edits[item_id]
  local desc_lines = { DESC_HEADER }
  if desc_edit.description == "" then
    table.insert(desc_lines, "")
  else
    for _, line in ipairs(vim.split(desc_edit.description, "\n", { plain = true })) do
      table.insert(desc_lines, line)
    end
  end

  local desc_buf = get_or_create_description_buffer()
  vim.bo[desc_buf].modifiable = true
  vim.api.nvim_buf_set_lines(desc_buf, 0, -1, false, desc_lines)
  vim.api.nvim_buf_set_name(desc_buf, "workhorse://description/#" .. item_id)

  -- Load tags content (add empty line only if no tags)
  local tags_edit = tags_edits[item_id]
  local tags_lines = { TAGS_HEADER }
  if #tags_edit.tags == 0 then
    table.insert(tags_lines, "")
  else
    for _, tag in ipairs(tags_edit.tags) do
      table.insert(tags_lines, tag)
    end
  end

  local tags_buf = get_or_create_tags_buffer()
  vim.bo[tags_buf].modifiable = true
  vim.api.nvim_buf_set_lines(tags_buf, 0, -1, false, tags_lines)
  vim.api.nvim_buf_set_name(tags_buf, "workhorse://tags/#" .. item_id)

  -- Position cursors on line 2 (after headers)
  vim.api.nvim_win_set_cursor(desc_winid, { 2, 0 })
  vim.api.nvim_win_set_cursor(tags_winid, { 2, 0 })
end

-- Get all pending description changes
function M.get_pending_description_changes()
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

-- Get all pending tag changes
function M.get_pending_tag_changes()
  local changes = {}
  for item_id, edit in pairs(tags_edits) do
    if edit.modified then
      table.insert(changes, {
        id = item_id,
        tags = edit.tags,
      })
    end
  end
  return changes
end

-- Check if there are any pending description changes
function M.has_pending_description_changes()
  for _, edit in pairs(description_edits) do
    if edit.modified then
      return true
    end
  end
  return false
end

-- Check if there are any pending tag changes
function M.has_pending_tag_changes()
  for _, edit in pairs(tags_edits) do
    if edit.modified then
      return true
    end
  end
  return false
end

-- Check if there are any pending changes (description or tags)
function M.has_pending_changes()
  return M.has_pending_description_changes() or M.has_pending_tag_changes()
end

-- Mark a description as saved (after successful API call)
function M.mark_description_saved(item_id)
  if description_edits[item_id] then
    description_edits[item_id].original = description_edits[item_id].description
    description_edits[item_id].modified = false
  end
end

-- Mark tags as saved (after successful API call)
function M.mark_tags_saved(item_id)
  if tags_edits[item_id] then
    tags_edits[item_id].original = vim.deepcopy(tags_edits[item_id].tags)
    tags_edits[item_id].modified = false
  end
end

-- Clear all edits (e.g., after refresh)
function M.clear_edits()
  description_edits = {}
  tags_edits = {}
end

-- Update stored description from refreshed work item
function M.update_from_item(work_item)
  local item_id = work_item.id

  -- Update description
  local desc_edit = description_edits[item_id]
  if desc_edit and not desc_edit.modified then
    local plain_text = html_to_text(work_item.description or "")
    desc_edit.description = plain_text
    desc_edit.original = plain_text
  end

  -- Update tags
  local tags_edit = tags_edits[item_id]
  if tags_edit and not tags_edit.modified then
    local tags_array = parse_tags(work_item.tags or "")
    tags_edit.tags = vim.deepcopy(tags_array)
    tags_edit.original = vim.deepcopy(tags_array)
  end
end

return M
