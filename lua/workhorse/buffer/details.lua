-- Details of one work item, opened by <CR> on the work item buffers (flat or tree): one editable
-- buffer in a popup, styled like the repository screen (repos_screen/repo.lua):
--
--   #123 Fix the login page   User Story · Active · Area   (meta as virtual text)
--   ───── ◇ ─────                                         (virtual line: never in the text)
--   Column: Doing
--   Tags: frontend, urgent
--
--   Description
--     Free text of the description, indented one level
--
--   Attachments
--     report.pdf                                          (a link: gx downloads it)
--     ~/Documents/Attachments/screenshot.png              (a new line: attached on save)
--
--   Discussion Comment
--     Free text of a new comment, added to the discussion on save
--
--   Discussion History                                    (read-only, newest first)
--     Author · 19/10/26 14:32
--       Text of the comment
--
-- Column and Tags are completed from their choices (ui/choices.lua; the tags one at a time),
-- <Tab>/<S-Tab> move between them, the description and the comment. The history is plain text
-- (it can be yanked and searched) that is never parsed: edits there are not saved, and a render
-- puts it back. The attachments are one per line, by name: deleting a line removes the file from
-- the work item, and a new line attaches a file (a path, or the name of a file of an attachment
-- folder, completed from those folders: see attachments.lua). The column is the board column, as
-- <leader>ws moves it: the state follows it on the server, through the board's state mappings.
-- A missing Column or Tags line keeps that field as it is. Saving (<leader><leader> in normal
-- mode, <C-CR> in insert mode; :w does nothing) confirms the pending changes of the details of
-- every work item together, sends them (one request per work item), then refreshes the work item
-- buffer the details were opened from. <CR> in normal mode saves and closes: the popup closes once
-- the save is confirmed (or at once when there is nothing to save). There is one buffer per work
-- item, hidden when the popup closes (q / <Esc>): its unsaved edits stay, even when the details of
-- other work items are opened later, until they are saved, reloaded or discarded by a refresh of
-- the query.
local M = {}

local config = require("workhorse.config")
local guides = require("workhorse.buffer_tree.guides")
local pinned = require("workhorse.ui.pinned")
local choices = require("workhorse.ui.choices")
local workitems = require("workhorse.api.workitems")
local attachments = require("workhorse.attachments")
local boards = require("workhorse.api.boards")

local ns = vim.api.nvim_create_namespace("workhorse_details")
-- The separator, drawn apart so a resize redraws it alone
local rules_ns = vim.api.nvim_create_namespace("workhorse_details_rules")

local COLUMN, TAGS = "Column", "Tags"
local FIELD_OF_KEY = { [COLUMN:lower()] = "column", [TAGS:lower()] = "tags" }
-- The section headers, in the order they come in the buffer
local SECTIONS = {
  { key = "description", title = "Description" },
  { key = "attachments", title = "Attachments" },
  { key = "comment", title = "Discussion Comment" },
  { key = "history", title = "Discussion History" },
}
local SECTION_OF_TITLE = {}
for _, section in ipairs(SECTIONS) do
  SECTION_OF_TITLE[section.title] = section.key
end

-- [work item id] = bufnr
local screens = {}
-- [bufnr] = { item, origin = work item buffer it was opened from, saving, comments (nil until
-- loaded), comments_error, comments_request (the latest), history (the rendered history lines:
-- { text, author = byte length of the author on an author line }), attachments (the files
-- attached, see workitems.list_attachments; nil until loaded), attachments_error,
-- attachments_request (the latest) }
local buffers = {}
-- The split on the right showing the details
local details_win = nil
-- Tags of the project (nil until loaded)
local project_tags, tags_loading = nil, false
-- Boards of the team, with their columns and column field (nil until loaded)
local board_list, boards_loading = nil, false

local function notify(msg, level)
  vim.notify("Workhorse: " .. msg, level or vim.log.levels.INFO)
end

-- Conversions -------------------------------------------------------------------

-- Convert HTML description to plain text (basic)
local function html_to_text(html)
  if not html or html == "" then
    return ""
  end
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
  text = text:gsub("&quot;", '"')
  text = text:gsub("&#(%d+);", function(code)
    return vim.fn.nr2char(tonumber(code))
  end)
  -- Last, so an escaped "&amp;lt;" stays "&lt;"
  text = text:gsub("&amp;", "&")
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
  text = text:gsub("&", "&amp;")
  text = text:gsub("<", "&lt;")
  text = text:gsub(">", "&gt;")
  text = text:gsub("\n", "<br>")
  return text
end

-- Tags of a "a; b" (server) or "a, b" (buffer) string, trimmed, without blanks or repeats
local function split_tags(text)
  local tags, seen = {}, {}
  for tag in (text or ""):gmatch("[^;,]+") do
    local trimmed = vim.trim(tag)
    if trimmed ~= "" and not seen[trimmed:lower()] then
      seen[trimmed:lower()] = true
      table.insert(tags, trimmed)
    end
  end
  return tags
end

-- Tags of `a` missing from `b`, ignoring case
local function tags_missing(a, b)
  local present = {}
  for _, tag in ipairs(b) do
    present[tag:lower()] = true
  end
  return vim.tbl_filter(function(tag)
    return not present[tag:lower()]
  end, a)
end

-- Board of the work item's type: the one whose columns map the states of that type
local function board_of(item)
  for _, board in ipairs(board_list or {}) do
    for _, column in ipairs(board.columns or {}) do
      if type(column.stateMappings) == "table" and column.stateMappings[item.type] then
        return board
      end
    end
  end
end

-- Columns the work item can move to (nil while the boards load): those of the board of its
-- type, or of all the boards when none maps it
local function allowed_columns(item)
  if not board_list then
    return nil
  end
  local board = board_of(item)
  return board and board.order or boards.merge_boards(board_list).order
end

local function title(item)
  return ("#%d %s"):format(item.id, item.title or "")
end

-- Line 1 is the title while it starts with the "#" of the id (it may have been deleted)
local function is_title(lnum, line)
  return lnum == 1 and (line or ""):match("^#") ~= nil
end

-- Key of the section a header line starts ("description", "attachments", "comment", "history"),
-- nil for others
local function header_key(line)
  return SECTION_OF_TITLE[(line or ""):match("^(%S.-)%s*$") or ""]
end

local function is_header(line)
  return header_key(line) ~= nil
end

-- Line numbers of the section headers ({ description, comment, history }, the first of each),
-- missing for those deleted
local function header_lnums(lines)
  local found = {}
  for lnum, line in ipairs(lines) do
    local key = lnum > 1 and header_key(line)
    if key and not found[key] then
      found[key] = lnum
    end
  end
  return found
end

-- The first line of the buffer after `lnum` that is a header, or one past the last line
local function next_header(lines, lnum)
  for l = lnum + 1, #lines do
    if is_header(lines[l]) then
      return l
    end
  end
  return #lines + 1
end

-- Whether `lnum` is in the text of the description or of the comment
local function in_text(lines, lnum)
  local headers = header_lnums(lines)
  for _, key in ipairs({ "description", "comment" }) do
    local header = headers[key]
    if header and lnum > header and lnum < next_header(lines, header) then
      return true
    end
  end
  return false
end

local function dedent(line)
  return line:sub(math.min(#line:match("^ *"), guides.width()) + 1)
end

-- Text of the section under the header at `header`: dedented, without blank lines around it
local function section_text(lines, header)
  local text = vim.tbl_map(dedent, vim.list_slice(lines, header + 1, next_header(lines, header) - 1))
  while #text > 0 and vim.trim(text[1]) == "" do
    table.remove(text, 1)
  end
  while #text > 0 and vim.trim(text[#text]) == "" do
    table.remove(text)
  end
  return table.concat(text, "\n")
end

-- Parsing and changes -----------------------------------------------------------

-- Lines of the attachments section under the header at `header`: { { lnum, text (trimmed) } },
-- blank lines left out
local function attachment_lines(lines, header)
  local result = {}
  for lnum = header + 1, next_header(lines, header) - 1 do
    local text = vim.trim(lines[lnum])
    if text ~= "" then
      table.insert(result, { lnum = lnum, text = text })
    end
  end
  return result
end

-- { column, tags, description, comment, attachments (see attachment_lines), lnums = { column,
-- tags, description, attachments, comment, history (the headers) } } of the buffer, plus the
-- lines that are no field. The history is not parsed
local function parse(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local headers = header_lnums(lines)
  local result, errors = { lnums = {} }, {}
  for lnum = 1, next_header(lines, 1) - 1 do
    local line = lines[lnum]
    if not is_title(lnum, line) and not line:match("^%s*$") then
      local key, value = line:match("^%s*([^:]+):%s*(.-)%s*$")
      local field = key and FIELD_OF_KEY[vim.trim(key):lower()]
      if field and result[field] == nil then
        result[field] = field == "tags" and split_tags(value) or value
        result.lnums[field] = lnum
      else
        table.insert(errors, ("Line %d: not a field: %s"):format(lnum, vim.trim(line)))
      end
    end
  end
  for _, key in ipairs({ "description", "comment" }) do
    if headers[key] then
      result[key] = section_text(lines, headers[key])
    end
  end
  if headers.attachments then
    result.attachments = attachment_lines(lines, headers.attachments)
  end
  for _, section in ipairs(SECTIONS) do
    result.lnums[section.key] = headers[section.key]
  end
  return result, errors
end

-- The attachments the lines of the section stand for, against the files attached `existing` (nil
-- while loading: then every line is a new file): sets on each line `attachment` (an existing one,
-- matched by name, in order for repeated names) or `path` and `size` (a new one) or `problem`.
-- Returns { add = lines of new files, remove = attachments without a line } or nil when nothing
-- changes
local function match_attachments(lines, existing)
  local pool = {}
  for _, attachment in ipairs(existing or {}) do
    pool[attachment.name] = pool[attachment.name] or {}
    table.insert(pool[attachment.name], attachment)
  end
  local add, paths = {}, {}
  for _, line in ipairs(lines) do
    local same = pool[line.text]
    if same and #same > 0 then
      line.attachment = table.remove(same, 1)
    else
      local path, stat = attachments.resolve(line.text)
      if not path then
        line.problem = "file not found"
      elseif paths[path] then
        line.problem = "attached twice (line " .. paths[path] .. ")"
      else
        paths[path] = line.lnum
        line.path, line.size = path, stat.size
        table.insert(add, line)
      end
    end
  end
  local remove = {}
  for _, attachment in ipairs(existing or {}) do
    if vim.tbl_contains(pool[attachment.name], attachment) then
      table.insert(remove, attachment)
    end
  end
  if #add + #remove == 0 then
    return nil
  end
  return { add = add, remove = remove }
end

-- The changes of the buffer ({ column, tags, added, removed, description, comment, attachments },
-- each only when changed), the errors that block saving them, the parsed buffer, and the problem
-- of each field. A missing or misplaced header blocks saving: the text around it would land in another
-- section (the history in the new comment, for one)
local function detect(bufnr)
  local item = buffers[bufnr].item
  local parsed, errors = parse(bufnr)
  local changes, problems = {}, {}
  local previous = 0
  for _, section in ipairs(SECTIONS) do
    local lnum = parsed.lnums[section.key]
    if not lnum then
      table.insert(errors, "The " .. section.title .. " line is missing (<leader>R reloads)")
    elseif lnum < previous then
      table.insert(errors, ("Line %d: the %s line is out of place (<leader>R reloads)"):format(lnum, section.title))
    else
      previous = lnum
    end
  end
  if parsed.column and parsed.column ~= (item.board_column or "") then
    local columns = allowed_columns(item)
    local match
    for _, column in ipairs(columns or {}) do
      if column:lower() == parsed.column:lower() then
        match = column
      end
    end
    if parsed.column == "" then
      problems.column = "cannot be emptied"
    elseif not columns then
      problems.column = "is unknown until the board columns load"
    elseif not match then
      problems.column = "is not a column of the board of " .. item.type
    elseif match ~= item.board_column then
      changes.column = match
    end
    if problems.column then
      table.insert(errors, ("Line %d: the column %s"):format(parsed.lnums.column, problems.column))
    end
  end
  if parsed.tags then
    local before = split_tags(item.tags)
    local added, removed = tags_missing(parsed.tags, before), tags_missing(before, parsed.tags)
    if #added + #removed > 0 then
      changes.tags, changes.added, changes.removed = parsed.tags, added, removed
    end
  end
  if parsed.description and parsed.description ~= html_to_text(item.description) then
    changes.description = parsed.description
  end
  if parsed.comment and parsed.comment ~= "" then
    changes.comment = parsed.comment
  end
  if parsed.attachments then
    changes.attachments = match_attachments(parsed.attachments, buffers[bufnr].attachments)
    for _, line in ipairs(parsed.attachments) do
      if line.problem then
        table.insert(errors, ("Line %d: %s: %s"):format(line.lnum, line.text, line.problem))
      end
    end
  end
  return changes, errors, parsed, problems
end

local function pending(bufnr)
  local changes, errors = detect(bufnr)
  return next(changes) ~= nil or #errors > 0
end

-- "+added -removed" of a tags change
local function tags_summary(changes)
  local parts = {}
  for _, tag in ipairs(changes.added) do
    table.insert(parts, "+" .. tag)
  end
  for _, tag in ipairs(changes.removed) do
    table.insert(parts, "-" .. tag)
  end
  return table.concat(parts, " ")
end

-- Decoration --------------------------------------------------------------------

-- The separator under the title, as the repository screen draws it, across the window
local function draw_rules(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, rules_ns, 0, -1)
  local first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
  if not is_title(1, first) then
    return
  end
  local win = vim.fn.win_findbuf(bufnr)[1]
  local width = win and (vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff) or vim.o.columns
  vim.api.nvim_buf_set_extmark(bufnr, rules_ns, 0, 0, { virt_lines = { require("workhorse.ui.header").rule(width) } })
  -- The title and the rule under it stay frozen at the top while scrolling
  pinned.schedule_refresh(bufnr)
end

--- Highlights and hints of the whole buffer; the buffer is modified while it has changes
function M.decorate(bufnr)
  local state = buffers[bufnr]
  if not state then
    return
  end
  local item = state.item
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  guides.draw(bufnr, { boundary = is_header })
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- opts.col: the column the mark starts at (not an extmark option: it is the API's argument)
  local function mark(lnum, opts)
    local col = opts.col or 0
    opts.col = nil
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, col, opts)
  end
  if is_title(1, lines[1]) then
    local meta = vim.tbl_filter(function(part)
      return part ~= ""
    end, { item.type or "", item.state or "", item.area_path or "" })
    mark(1, { end_col = #lines[1], hl_group = "WorkhorseBuildHeader" })
    mark(1, { virt_text = { { table.concat(meta, " · "), "WorkhorseBuildMeta" } }, virt_text_pos = "right_align" })
  end

  local changes, errors, parsed, problems = detect(bufnr)
  -- Key and value of a field line, and its hint
  local function field(lnum, value_hl, virt)
    local line = lines[lnum]
    local colon = line:find(":", 1, true)
    mark(lnum, { col = #line:match("^%s*"), end_col = colon, hl_group = "WorkhorseRunKey" })
    if value_hl then
      mark(lnum, { col = colon, end_col = #line, hl_group = value_hl })
    end
    if virt then
      mark(lnum, { virt_text = { virt } })
    end
  end
  if parsed.lnums.column then
    local colors = config.get().column_colors or {}
    local virt
    if problems.column then
      virt = { "  " .. problems.column, "WorkhorseRunRequired" }
    elseif changes.column then
      local was = item.board_column ~= "" and item.board_column or "no column"
      virt = { "  [was " .. was .. "]", "DiagnosticWarn" }
    end
    field(parsed.lnums.column, colors[changes.column or item.board_column], virt)
  end
  if parsed.lnums.tags then
    field(parsed.lnums.tags, nil, changes.tags and { "  " .. tags_summary(changes), "DiagnosticWarn" } or nil)
  end
  for _, section in ipairs(SECTIONS) do
    local header = parsed.lnums[section.key]
    if header then
      mark(header, { end_col = #lines[header], hl_group = "WorkhorseRunSection" })
      mark(header, { end_col = #lines[header], hl_group = "WorkhorseBold", priority = 4097 })
    end
  end
  if parsed.lnums.description and changes.description then
    mark(parsed.lnums.description, { virt_text = { { "  [modified]", "DiagnosticWarn" } } })
  end
  if parsed.lnums.comment and changes.comment then
    mark(parsed.lnums.comment, { virt_text = { { "  [new comment]", "DiagnosticWarn" } } })
  end
  if parsed.lnums.attachments then
    local header = parsed.lnums.attachments
    local chunks
    if state.attachments_error then
      chunks = { { "  failed to load: " .. tostring(state.attachments_error), "WorkhorseRunRequired" } }
    elseif not state.attachments then
      chunks = { { "  loading…", "WorkhorseBuildMeta" } }
    elseif #parsed.attachments == 0 and not changes.attachments then
      chunks = { { "  none · a new line attaches a file", "WorkhorseBuildMeta" } }
    else
      local n = #state.attachments
      chunks = { { ("  %d file%s · gx downloads"):format(n, n == 1 and "" or "s"), "WorkhorseBuildMeta" } }
    end
    if changes.attachments then
      local parts = {}
      if #changes.attachments.add > 0 then
        table.insert(parts, "+" .. #changes.attachments.add)
      end
      for _, attachment in ipairs(changes.attachments.remove) do
        table.insert(parts, "-" .. attachment.name)
      end
      table.insert(chunks, { "  [" .. table.concat(parts, " ") .. "]", "DiagnosticWarn" })
    end
    mark(header, { virt_text = chunks })
    for _, line in ipairs(parsed.attachments) do
      local text = lines[line.lnum]
      local start = #text:match("^%s*")
      if line.attachment then
        -- The URL makes the line a link: gx (vim.ui._get_urls) and terminal hyperlinks open it
        mark(line.lnum, { col = 0, end_col = #text, hl_group = "WorkhorseBuildTitle",
          url = workitems.attachment_download_url(line.attachment) })
        local meta = vim.tbl_filter(function(part)
          return part ~= ""
        end, {
          attachments.format_size(line.attachment.size),
          require("workhorse.api.builds").format_date(line.attachment.date),
        })
        mark(line.lnum, { virt_text = { { "  " .. table.concat(meta, " · "), "WorkhorseBuildMeta" } } })
      elseif line.problem then
        mark(line.lnum, { virt_text = { { "  " .. line.problem, "WorkhorseRunRequired" } } })
      else
        mark(line.lnum, { col = start, end_col = #text, hl_group = "DiagnosticWarn" })
        mark(line.lnum, { virt_text = { { ("  [new · %s]"):format(attachments.format_size(line.size)),
          "DiagnosticWarn" } } })
      end
    end
  end
  local history = parsed.lnums.history
  if history then
    -- The history as rendered: highlighted while untouched, flagged once edited
    local expected = state.history or {}
    local edited = #lines - history ~= #expected
    for i, entry in ipairs(expected) do
      local lnum = history + i
      if lines[lnum] ~= entry.text then
        edited = true
      elseif entry.author then
        local indent = #entry.text:match("^%s*")
        mark(lnum, { col = indent, end_col = indent + entry.author, hl_group = "WorkhorseBuildTitle" })
        mark(lnum, { col = indent + entry.author, end_col = #entry.text, hl_group = "WorkhorseBuildDate" })
      end
    end
    local virt
    if state.comments_error then
      virt = { "  failed to load: " .. tostring(state.comments_error), "WorkhorseRunRequired" }
    elseif not state.comments then
      virt = { "  loading…", "WorkhorseBuildMeta" }
    else
      local n = #state.comments
      virt = { ("  %d comment%s · read-only"):format(n, n == 1 and "" or "s"), "WorkhorseBuildMeta" }
    end
    local chunks = { virt }
    if edited then
      table.insert(chunks, { "  [edits here are not saved: <leader>R restores]", "DiagnosticWarn" })
    end
    mark(history, { virt_text = chunks })
  end
  draw_rules(bufnr)
  vim.bo[bufnr].modified = next(changes) ~= nil or #errors > 0
end

-- Rendering ---------------------------------------------------------------------

-- `text` as lines at indent `level` (blank lines left empty)
local function indented(text, level)
  local prefix = guides.prefix(level)
  return vim.tbl_map(function(line)
    return line:match("^%s*$") and "" or prefix .. line
  end, vim.split(text, "\n", { plain = true }))
end

-- Lines of the attachments section (without the header): one per file, or an indented blank
-- line when there are none (typing there starts at the level of the list)
local function attachments_section(state)
  if not state.attachments or #state.attachments == 0 then
    return { guides.prefix(1) }
  end
  return vim.tbl_map(function(attachment)
    return guides.prefix(1) .. attachment.name
  end, state.attachments)
end

-- Lines of the discussion history ({ text, author }, see `buffers`), newest comment first
local function history_lines(state)
  local result = {}
  for i, comment in ipairs(state.comments or {}) do
    if i > 1 then
      table.insert(result, { text = "" })
    end
    local date = require("workhorse.api.builds").format_date(comment.date)
    table.insert(result, {
      text = guides.prefix(1) .. comment.author .. (date ~= "" and (" · " .. date) or ""),
      author = #comment.author,
    })
    local text = html_to_text(comment.text)
    for _, line in ipairs(indented(text ~= "" and text or "(empty)", 2)) do
      table.insert(result, { text = line })
    end
  end
  return result
end

-- Replace lines of the buffer keeping the view; `clean` leaves no undo step behind (and drops the
-- undo history: the buffer then is what the server has)
local function set_lines(bufnr, first, last, lines, clean)
  local win = vim.fn.win_findbuf(bufnr)[1]
  local view = win and vim.api.nvim_win_call(win, vim.fn.winsaveview)
  local undolevels = vim.bo[bufnr].undolevels
  if clean then
    vim.bo[bufnr].undolevels = -1
  end
  vim.api.nvim_buf_set_lines(bufnr, first, last, false, lines)
  if clean then
    vim.bo[bufnr].undolevels = undolevels
  end
  if view then
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview(view)
    end)
  end
end

local function render(bufnr)
  local state = buffers[bufnr]
  local item = state.item
  local lines = {
    title(item),
    COLUMN .. ": " .. (item.board_column or ""),
    TAGS .. ": " .. table.concat(split_tags(item.tags), ", "),
    "",
    SECTIONS[1].title,
  }
  local text = html_to_text(item.description)
  -- An empty section gets an indented line, so typing starts at the level of its text
  vim.list_extend(lines, text == "" and { guides.prefix(1) } or indented(text, 1))
  vim.list_extend(lines, { "", SECTIONS[2].title })
  vim.list_extend(lines, attachments_section(state))
  vim.list_extend(lines, { "", SECTIONS[3].title, guides.prefix(1), "", SECTIONS[4].title })
  state.history = history_lines(state)
  for _, entry in ipairs(state.history) do
    table.insert(lines, entry.text)
  end
  set_lines(bufnr, 0, -1, lines, true)
  M.decorate(bufnr)
  vim.bo[bufnr].modified = false
end

-- Put the loaded comments in the history section (when its header is still there): without an
-- undo step while the buffer has no changes of its own
local function render_history(bufnr)
  local state = buffers[bufnr]
  if not state or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local header = header_lnums(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)).history
  if header then
    local clean = not pending(bufnr)
    state.history = history_lines(state)
    set_lines(bufnr, header, -1, vim.tbl_map(function(entry)
      return entry.text
    end, state.history), clean)
  end
  M.decorate(bufnr)
end

-- Put the loaded attachments in their section (when its header is still there). Without changes
-- of its own the buffer takes them as they are, without an undo step; on the first load, the
-- lines typed meanwhile (new files) stay below them; `force` replaces the section all the same
-- (after a save: its new lines were attached). Otherwise the edits stay, diffed against them
local function render_attachments(bufnr, previous, force)
  local state = buffers[bufnr]
  if not state or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local header = header_lnums(lines).attachments
  if header then
    -- The whole section, then the blank line that separates the next one
    local stop = next_header(lines, header)
    local tail = stop <= #lines and { "" } or {}
    local saved_state = state.attachments
    state.attachments = previous
    local clean = not pending(bufnr)
    state.attachments = saved_state
    if clean or force then
      set_lines(bufnr, header, stop - 1, vim.list_extend(attachments_section(state), tail), clean)
    elseif previous == nil and not state.attachments_error then
      local typed = vim.tbl_map(function(line)
        return lines[line.lnum]
      end, attachment_lines(lines, header))
      local section = #state.attachments > 0 and attachments_section(state) or {}
      set_lines(bufnr, header, stop - 1, vim.list_extend(vim.list_extend(section, typed), tail), false)
    end
  end
  M.decorate(bufnr)
end

-- Load the files attached to the work item, then show them (only the latest request counts)
local function load_attachments(bufnr, force)
  local state = buffers[bufnr]
  state.attachments_request = (state.attachments_request or 0) + 1
  local request = state.attachments_request
  workitems.list_attachments(state.item.id, function(list, err)
    if buffers[bufnr] ~= state or state.attachments_request ~= request then
      return
    end
    local previous = state.attachments
    state.attachments, state.attachments_error = list, list == nil and (err or "unknown error") or nil
    if list == nil then
      -- Keep diffing against the files known before, if any
      state.attachments = previous
    end
    render_attachments(bufnr, previous, force)
  end)
end

-- Load the discussion comments of the work item, then show them (only the latest request counts)
local function load_comments(bufnr)
  local state = buffers[bufnr]
  state.comments_request = (state.comments_request or 0) + 1
  local request = state.comments_request
  workitems.list_comments(state.item.id, function(comments, err)
    if buffers[bufnr] ~= state or state.comments_request ~= request then
      return
    end
    state.comments, state.comments_error = comments, comments == nil and (err or "unknown error") or nil
    render_history(bufnr)
  end)
end

-- Tags of the project, loaded once (completion falls back to the item's own tags meanwhile)
local function load_tags(bufnr)
  if project_tags or tags_loading then
    return
  end
  tags_loading = true
  workitems.list_tags(function(names)
    tags_loading = false
    project_tags = names or {}
    if vim.api.nvim_buf_is_valid(bufnr) then
      choices.refresh(bufnr)
    end
  end)
end

-- Boards the columns come from, as the work item buffers fetch them
local function board_names()
  local cfg = config.get()
  local names, seen = {}, {}
  for _, name in ipairs(vim.list_extend({ cfg.default_board or "Stories" }, vim.deepcopy(cfg.column_boards or {}))) do
    if name ~= "" and not seen[name] then
      seen[name] = true
      table.insert(names, name)
    end
  end
  return names
end

-- Boards of the team, loaded once (again on a reload of the details when they failed)
local function load_boards()
  if board_list or boards_loading then
    return
  end
  boards_loading = true
  boards.get_boards(board_names(), function(data_list)
    boards_loading = false
    if not data_list or #data_list == 0 then
      notify("Failed to fetch the board columns (<leader>R in the details retries)", vim.log.levels.WARN)
      return
    end
    board_list = data_list
    for bufnr in pairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        choices.refresh(bufnr)
        M.decorate(bufnr)
      end
    end
  end)
end

-- Tags offered on the Tags line `line`: the project's and the item's, but those already on it
-- Whether `lnum` is a line of the attachments section
local function in_attachments(lines, lnum)
  local header = header_lnums(lines).attachments
  return header ~= nil and lnum > header and lnum < next_header(lines, header)
end

-- Files offered on the line `lnum` of the attachments section: those of the attachment folders
-- (as ~ paths, newest first), but those already on another line
local function attachment_choices(lines, lnum)
  local taken = {}
  local header = header_lnums(lines).attachments
  for _, line in ipairs(attachment_lines(lines, header)) do
    if line.lnum ~= lnum then
      local path = attachments.resolve(line.text)
      if path then
        taken[path] = true
      end
    end
  end
  local result = {}
  for _, file in ipairs(attachments.list()) do
    if not taken[file.path] then
      table.insert(result, vim.fn.fnamemodify(file.path, ":~"))
    end
  end
  return result
end

local function tag_choices(item, line)
  local on_line = split_tags(line:match(":(.*)$"))
  local all = split_tags(table.concat(vim.list_extend(vim.deepcopy(project_tags or {}),
    split_tags(item.tags)), ";"))
  table.sort(all, function(a, b)
    return a:lower() < b:lower()
  end)
  return tags_missing(all, on_line)
end

-- Navigation ----------------------------------------------------------------------

-- Places <Tab> moves to: { lnum, kind = "value" | "text" }, the fields then the description,
-- the attachments and the comment (the line under their header)
local function stops(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local headers = header_lnums(lines)
  local result = {}
  for lnum = 1, next_header(lines, 1) - 1 do
    if not is_title(lnum, lines[lnum]) and lines[lnum]:match("^%s*[^%s:][^:]*:") then
      table.insert(result, { lnum = lnum, kind = "value" })
    end
  end
  for _, key in ipairs({ "description", "attachments", "comment" }) do
    if headers[key] then
      table.insert(result, { lnum = headers[key] + 1, kind = "text" })
    end
  end
  return result
end

--- Move the cursor to the next (dir = 1) or previous (dir = -1) field value, or to the
--- description: the Column value at its start, the Tags at the end of the line (to add one)
function M.jump(dir)
  local bufnr = vim.api.nvim_get_current_buf()
  local list = stops(bufnr)
  if #list == 0 then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local current = 0
  for i, stop in ipairs(list) do
    if stop.lnum <= row then
      current = i
    end
  end
  if current == 0 and dir < 0 then
    current = 1
  end
  local target = list[(current - 1 + dir) % #list + 1]
  local under = vim.api.nvim_buf_get_lines(bufnr, target.lnum - 1, target.lnum, false)[1]
  if target.kind == "text" and (not under or is_header(under)) then
    -- The section is empty and its blank line deleted: give it one back
    vim.api.nvim_buf_set_lines(bufnr, target.lnum - 1, target.lnum - 1, false, { guides.prefix(1) })
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, target.lnum - 1, target.lnum, false)[1]
  local col
  if target.kind == "value" then
    -- "Key:" without a space: add it, so typing starts after it
    if line:match(":$") then
      line = line .. " "
      vim.api.nvim_buf_set_lines(bufnr, target.lnum - 1, target.lnum, false, { line })
    end
    local key = vim.trim(line:match("^%s*([^:]+):")):lower()
    local value = line:find("%S", line:find(":", 1, true) + 1)
    col = (FIELD_OF_KEY[key] == "tags" or not value) and #line or value - 1
  else
    col = #line:match("^%s*")
  end
  vim.api.nvim_win_set_cursor(0, { target.lnum, col })
end

-- Window ------------------------------------------------------------------------------

-- Whether the details popup is open, showing a details buffer
local function details_open()
  return details_win and vim.api.nvim_win_is_valid(details_win)
    and buffers[vim.api.nvim_win_get_buf(details_win)] ~= nil
end

local function close()
  if details_open() then
    local origin = buffers[vim.api.nvim_win_get_buf(details_win)].origin
    -- The buffer is only hidden (bufhidden=hide): its edits survive, even when the details of
    -- other work items are opened later
    pcall(vim.api.nvim_win_close, details_win, true)
    local win = origin and vim.api.nvim_buf_is_valid(origin) and vim.fn.bufwinid(origin)
    if win and win ~= -1 then
      vim.api.nvim_set_current_win(win)
    end
  end
  details_win = nil
end

local function show(bufnr)
  local title = (" %s "):format(buffers[bufnr].item.title and ("#%d"):format(buffers[bufnr].item.id) or "work item")
  local win_config = require("workhorse.builds.form").float_config(title)
  if details_open() then
    vim.api.nvim_win_set_config(details_win, { title = win_config.title, title_pos = "center" })
    vim.api.nvim_set_current_win(details_win)
  else
    details_win = vim.api.nvim_open_win(bufnr, true, win_config)
  end
  vim.api.nvim_win_set_buf(details_win, bufnr)
  vim.wo[details_win].wrap = true
  vim.wo[details_win].linebreak = true
end

-- Save ---------------------------------------------------------------------------------

-- Refresh the work item buffer the details came from, unless it has edits of its own
local function refresh_origin(origin)
  if not origin or not vim.api.nvim_buf_is_valid(origin) then
    return
  end
  local win = vim.fn.bufwinid(origin)
  if win == -1 then
    return
  end
  if vim.bo[origin].modified then
    notify("The work item list has unsaved edits: <leader>R there refreshes it", vim.log.levels.WARN)
    return
  end
  -- The refresh resolves its buffer from the current window
  vim.api.nvim_win_call(win, function()
    -- A failed work item keeps its edits: they must not stop this refresh with a question
    require("workhorse").refresh({ skip_pending = true })
  end)
end

--- The changes of the details buffer `bufnr` as confirmation `entries` and a `run(on_done)` that
--- sends them (on_done runs once it ended, well or not). nil without changes; nil and true when
--- it cannot be saved now (a message tells why)
local function prepare(bufnr)
  local state = buffers[bufnr]
  if not state then
    return nil
  end
  if state.saving then
    notify(("Wait for the save of #%d to finish"):format(state.item.id), vim.log.levels.WARN)
    return nil, true
  end
  local changes, errors = detect(bufnr)
  if #errors > 0 then
    notify(("#%d: %s"):format(state.item.id, table.concat(errors, "\n")), vim.log.levels.WARN)
    return nil, true
  end
  if not next(changes) then
    vim.bo[bufnr].modified = false
    return nil
  end
  local item = state.item
  local entries, fields = {}, {}
  -- The column field of the item's board (nil: update_fields looks it up on the work item)
  local board = board_of(item)
  local column_field = board and board.column_field
  if changes.column then
    local was = item.board_column ~= "" and item.board_column or "no column"
    table.insert(entries, { text = ("Column: %s -> %s"):format(was, changes.column), hl = "DiagnosticWarn" })
    -- No state: the server moves it with the column (setting both may break a workflow rule)
    fields.board_column = changes.column
  end
  if changes.tags then
    table.insert(entries, { text = "Tags: " .. tags_summary(changes), hl = "DiagnosticWarn" })
    fields.tags = table.concat(changes.tags, "; ")
  end
  if changes.description then
    table.insert(entries, { text = "Description: updated", hl = "DiagnosticWarn" })
    fields.description = text_to_html(changes.description)
  end
  if changes.comment then
    local count = select(2, changes.comment:gsub("\n", "")) + 1
    table.insert(entries, { text = ("Discussion: new comment (%d line%s)"):format(count, count == 1 and "" or "s"),
      hl = "DiagnosticWarn" })
    -- Through System.History: the comment goes in the same request as the other changes
    fields.history = text_to_html(changes.comment)
  end
  local files = changes.attachments
  if files then
    for _, line in ipairs(files.add) do
      table.insert(entries, { text = ("Attach: %s (%s)"):format(vim.fn.fnamemodify(line.path, ":~"),
        attachments.format_size(line.size)), hl = "DiagnosticOk" })
    end
    for _, attachment in ipairs(files.remove) do
      table.insert(entries, { text = "Remove attachment: " .. attachment.name, hl = "DiagnosticError" })
    end
  end
  local function run(on_done)
    state.saving = true
    local done = require("workhorse.progress").start("Saving #" .. item.id)
    -- Whether the attachments were changed already (a later failure still shows them)
    local attached = false
    local function fail(err)
      state.saving = false
      done(true)
      notify(("Failed to update #%d: %s"):format(item.id, tostring(err)), vim.log.levels.ERROR)
      on_done()
      if attached and vim.api.nvim_buf_is_valid(bufnr) then
        -- Its new lines are attached now: saving again would attach them twice
        load_attachments(bufnr, true)
      end
    end
    -- The files first: one upload each, then one request attaching them and removing the others
    local function apply_attachments(next_step)
      if not files then
        return next_step()
      end
      local added = {}
      local function upload(i)
        local line = files.add[i]
        if not line then
          local urls = vim.tbl_map(function(attachment)
            return attachment.url
          end, files.remove)
          return workitems.update_attachments(item.id, added, urls, function(ok, err)
            if not ok then
              return fail(err)
            end
            attached = true
            next_step()
          end)
        end
        local name = vim.fn.fnamemodify(line.path, ":t")
        workitems.upload_attachment(line.path, name, function(url, err)
          if not url then
            return fail(("uploading %s: %s"):format(name, tostring(err)))
          end
          table.insert(added, { url = url, name = name })
          upload(i + 1)
        end)
      end
      upload(1)
    end
    local function apply_fields(next_step)
      if not next(fields) then
        return next_step()
      end
      workitems.update_fields(item.id, fields, function(_, err)
        if err then
          return fail(err)
        end
        next_step()
      end, column_field)
    end
    apply_attachments(function()
      apply_fields(function()
        workitems.get(item.id, function(fresh)
          state.saving = false
          done()
          if fresh then
            state.item = fresh
          else
            -- Could not reload it: take the saved values as they were sent
            state.item.board_column = fields.board_column or item.board_column
            state.item.tags = fields.tags or item.tags
            state.item.description = fields.description or item.description
          end
          notify(("Updated #%d"):format(item.id))
          if vim.api.nvim_buf_is_valid(bufnr) then
            -- The comment was sent: its section starts empty again, and the history gets it
            render(bufnr)
            if fields.history then
              load_comments(bufnr)
            end
            if files then
              load_attachments(bufnr, true)
            end
          end
          on_done(state.origin)
        end)
      end)
    end)
  end
  return entries, run
end

--- Confirm the pending changes of the details of every work item, then send them all (each work
--- item in a request of its own, in parallel); the work item buffer they came from is refreshed
--- once they ended. With `opts.close`, the popup closes too (save and close): right after the
--- confirmation, or at once when there is nothing to apply; a cancelled confirmation keeps it open
function M.save(opts)
  opts = opts or {}
  local pending = {}
  for bufnr, state in pairs(buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) and (vim.bo[bufnr].modified or state.saving) then
      table.insert(pending, bufnr)
    end
  end
  table.sort(pending, function(a, b)
    return buffers[a].item.id < buffers[b].item.id
  end)
  local groups = {}
  for _, bufnr in ipairs(pending) do
    local item_entries, run = prepare(bufnr)
    if run == true then
      -- One cannot be saved now (its message was shown): nothing is sent
      return
    end
    if item_entries then
      table.insert(groups, { item = buffers[bufnr].item, entries = item_entries, run = run })
    end
  end
  if #groups == 0 then
    if opts.close then
      close()
    else
      notify("No changes to apply")
    end
    return
  end
  local entries, runs = {}, {}
  for _, group in ipairs(groups) do
    if #groups > 1 then
      table.insert(entries, { text = title(group.item), hl = "WorkhorseBuildHeader" })
    end
    for _, entry in ipairs(group.entries) do
      entry.text = (#groups > 1 and "  " or "") .. entry.text
      table.insert(entries, entry)
    end
    table.insert(runs, group.run)
  end
  local heading = #groups == 1 and ("Changes to #%d"):format(groups[1].item.id)
    or ("Changes to %d work items"):format(#groups)
  require("workhorse.ui.list_confirm").show(heading, entries, function(confirmed)
    if not confirmed then
      return
    end
    if opts.close then
      -- The saves go on with the buffers hidden: they keep the edits until each one ended
      close()
    end
    local left, origins = #runs, {}
    for _, run in ipairs(runs) do
      run(function(origin)
        if origin then
          origins[origin] = true
        end
        left = left - 1
        if left == 0 then
          for o in pairs(origins) do
            refresh_origin(o)
          end
        end
      end)
    end
  end)
end

--- The details with unsaved changes among the work items `ids` ({ [id] = true }, all when nil):
--- a list of { id, title }
function M.pending(ids)
  local list = {}
  for bufnr, state in pairs(buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified and (not ids or ids[state.item.id]) then
      table.insert(list, { id = state.item.id, title = state.item.title or "" })
    end
  end
  table.sort(list, function(a, b)
    return a.id < b.id
  end)
  return list
end

--- Drop the unsaved changes of the details of the work items `ids` ({ [id] = true }): their
--- buffers load the work item again
function M.discard(ids)
  for bufnr, state in pairs(buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified and ids[state.item.id] then
      vim.bo[bufnr].modified = false
      M.reload(bufnr)
    end
  end
end

--- Load the work item again, asking first when there are unsaved changes
--- Whether `bufnr` (default: current) is a work item details buffer
function M.is_details_buffer(bufnr)
  return buffers[bufnr or vim.api.nvim_get_current_buf()] ~= nil
end

function M.reload(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = buffers[bufnr]
  if not state then
    return
  end
  if state.saving then
    notify("Wait for the save to finish", vim.log.levels.WARN)
    return
  end
  if vim.bo[bufnr].modified and vim.fn.confirm("Discard the pending changes and reload?", "&Discard\n&Cancel", 2) ~= 1 then
    return
  end
  load_boards()
  workitems.get(state.item.id, function(fresh, err)
    if not fresh then
      notify(("Failed to reload #%d: %s"):format(state.item.id, tostring(err)), vim.log.levels.ERROR)
      return
    end
    state.item = fresh
    if vim.api.nvim_buf_is_valid(bufnr) then
      render(bufnr)
      load_comments(bufnr)
      load_attachments(bufnr, true)
    end
  end)
end

-- Buffer -------------------------------------------------------------------------------

local function web_url(item)
  local cfg = config.get()
  return cfg.server_url:gsub("/$", "") .. "/" .. cfg.project .. "/_workitems/edit/" .. item.id
end

local function setup_keymaps(bufnr)
  local function map(lhs, fn, desc, mode)
    vim.keymap.set(mode or "n", lhs, fn, { buffer = bufnr, silent = true, nowait = true, desc = "Workhorse: " .. desc })
  end
  local send = require("workhorse.ui.send")
  send.map(bufnr, function()
    M.save()
  end, "apply the pending changes of every work item")
  send.map_enter(bufnr, function()
    M.save({ close = true })
  end, "apply the pending changes of every work item and close the details")
  map("<leader>R", function()
    M.reload(bufnr)
  end, "reload the work item")
  -- Closing keeps the edits: the buffer of each work item stays hidden with them
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    map(lhs, close, "close the details (keeping the edits)")
  end
  for _, lhs in ipairs({ "gb", "gw" }) do
    map(lhs, function()
      require("workhorse.builds").open_url(web_url(buffers[bufnr].item))
    end, "open the work item in the browser")
  end
  require("workhorse.builds").map_yank(bufnr, function()
    require("workhorse.builds").open_url(web_url(buffers[bufnr].item))
  end, "the work item")
  map("<Tab>", function()
    M.jump(1)
  end, "next value")
  map("<S-Tab>", function()
    M.jump(-1)
  end, "previous value")
  -- Insert mode: move in an open completion menu; indent on a description or comment line still
  -- blank before the cursor; jump to the next value otherwise
  for dir, lhs in pairs({ [1] = "<Tab>", [-1] = "<S-Tab>" }) do
    vim.keymap.set("i", lhs, function()
      local menu = require("workhorse.builds.form").menu_key(dir)
      if menu then
        return menu
      end
      local lnum, col = unpack(vim.api.nvim_win_get_cursor(0))
      if in_text(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), lnum)
        and vim.api.nvim_get_current_line():sub(1, col):match("^%s*$") then
        return dir > 0 and "<C-t>" or "<C-d>"
      end
      return ("<Cmd>lua require('workhorse.buffer.details').jump(%d)<CR>"):format(dir)
    end, { buffer = bufnr, silent = true, expr = true, desc = "Workhorse: " .. (dir > 0 and "next" or "previous") .. " value" })
  end
  -- Accept a completion with <CR>; a plain new line otherwise
  vim.keymap.set("i", "<CR>", choices.insert_cr, { buffer = bufnr, silent = true, expr = true,
    desc = "Workhorse: accept the completion" })
end

local function setup_autocmds(bufnr)
  local group = vim.api.nvim_create_augroup("workhorse_details_" .. bufnr, { clear = true })
  -- :w (e.g. an auto-save plugin's) does nothing: 'modified' tracks the pending changes, so it
  -- stays as it is
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = bufnr,
    callback = function() end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.decorate(bufnr)
    end,
  })
  -- The separator spans the window
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
      local state = buffers[bufnr]
      buffers[bufnr] = nil
      if state and screens[state.item.id] == bufnr then
        screens[state.item.id] = nil
      end
    end,
  })
end

local function create(item)
  local bufnr = vim.api.nvim_create_buf(false, false)
  pcall(vim.api.nvim_buf_set_name, bufnr, "Workhorse|workitem|#" .. item.id)
  -- acwrite: :w goes to BufWriteCmd (which ignores it) instead of writing a file
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "workhorse-workitem"
  buffers[bufnr] = { item = item }
  screens[item.id] = bufnr
  guides.setup_buffer(bufnr)
  choices.attach(bufnr, {
    choices = function(b, lnum)
      local state = buffers[b]
      if not state then
        return nil
      end
      local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
      local line = lines[lnum] or ""
      if in_attachments(lines, lnum) then
        return attachment_choices(lines, lnum)
      end
      if lnum >= next_header(lines, 1) or is_title(lnum, line) then
        return nil
      end
      if not line:find(":", 1, true) then
        return { COLUMN .. ": ", TAGS .. ": " }
      end
      local field = FIELD_OF_KEY[vim.trim(line:match("^%s*([^:]*):")):lower()]
      if field == "column" then
        load_boards()
        return allowed_columns(state.item) or {}
      elseif field == "tags" then
        load_tags(b)
        return tag_choices(state.item, line), true
      end
    end,
    -- A line still without its ":" completes the key; a line of the attachments section is a
    -- file as a whole
    start = function(line, lnum)
      if lnum and in_attachments(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), lnum) then
        return #line:match("^%s*")
      end
      if not line:find(":", 1, true) then
        return #line:match("^%s*")
      end
    end,
  })
  setup_keymaps(bufnr)
  setup_autocmds(bufnr)
  pinned.attach(bufnr, function()
    return is_title(1, vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]) and 1 or 0
  end)
  return bufnr
end

--- Open the details of `work_item` in the popup (closing it when it already shows
--- them). `owner_bufnr` is the work item buffer they are opened from, refreshed after a save
function M.open(work_item, owner_bufnr)
  if not work_item then
    notify("No work item provided", vim.log.levels.WARN)
    return
  end
  local bufnr = screens[work_item.id]
  if bufnr and not vim.api.nvim_buf_is_valid(bufnr) then
    bufnr = nil
  end
  if bufnr and details_open() and vim.api.nvim_win_get_buf(details_win) == bufnr then
    close()
    return
  end
  local fresh = not bufnr
  if fresh then
    bufnr = create(work_item)
  else
    -- Pending edits are kept; otherwise the item of the work item buffer is newer, unless it
    -- predates a save made here
    local state = buffers[bufnr]
    if not vim.bo[bufnr].modified and not state.saving and (work_item.rev or 0) >= (state.item.rev or 0) then
      state.item = work_item
      fresh = true
    end
  end
  buffers[bufnr].origin = owner_bufnr
  show(bufnr)
  if fresh then
    render(bufnr)
    vim.api.nvim_win_set_cursor(details_win, { 1, 0 })
    M.jump(1)
    load_comments(bufnr)
    load_attachments(bufnr)
  else
    M.decorate(bufnr)
  end
  load_tags(bufnr)
  load_boards()
end

--- Take the refreshed `work_item` into its details buffer, unless that has unsaved changes
function M.sync(work_item)
  local bufnr = screens[work_item.id]
  local state = bufnr and buffers[bufnr]
  if not state or not vim.api.nvim_buf_is_valid(bufnr) or state.saving or vim.bo[bufnr].modified then
    return
  end
  state.item = work_item
  render(bufnr)
end

return M
