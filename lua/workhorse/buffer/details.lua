-- Details of one work item, opened by <CR> on the work item buffers (flat or tree): one editable
-- buffer in a split on the right, styled like the repository screen (repos_screen/repo.lua):
--
--   #123 Fix the login page   User Story · Active · Area   (meta as virtual text)
--   ───── ◇ ─────                                         (virtual line: never in the text)
--   Column: Doing
--   Tags: frontend, urgent
--
--   Description
--     Free text of the description, indented one level
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
-- puts it back. The column is the board column, as
-- <leader>ws moves it: the state follows it on the server, through the board's state mappings.
-- A missing Column or Tags line keeps that field as it is. Saving (<leader><leader>, or <CR>,
-- which then closes the details; :w does nothing) confirms the changes, sends them in one request, then refreshes the work item buffer the details were
-- opened from. There is one buffer per work item, hidden when its window closes: its unsaved
-- edits stay until it is saved or reloaded.
local M = {}

local config = require("workhorse.config")
local guides = require("workhorse.buffer_tree.guides")
local pinned = require("workhorse.ui.pinned")
local choices = require("workhorse.ui.choices")
local workitems = require("workhorse.api.workitems")
local boards = require("workhorse.api.boards")

local ns = vim.api.nvim_create_namespace("workhorse_details")
-- The separator, drawn apart so a resize redraws it alone
local rules_ns = vim.api.nvim_create_namespace("workhorse_details_rules")

local COLUMN, TAGS = "Column", "Tags"
local FIELD_OF_KEY = { [COLUMN:lower()] = "column", [TAGS:lower()] = "tags" }
-- The section headers, in the order they come in the buffer
local SECTIONS = {
  { key = "description", title = "Description" },
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
-- { text, author = byte length of the author on an author line }) }
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

-- Key of the section a header line starts ("description", "comment", "history"), nil for others
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

-- { column, tags, description, comment, lnums = { column, tags, description, comment, history
-- (the headers) } } of the buffer, plus the lines that are no field. The history is not parsed
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
  for _, section in ipairs(SECTIONS) do
    result.lnums[section.key] = headers[section.key]
  end
  return result, errors
end

-- The changes of the buffer ({ column, tags, added, removed, description, comment }, each only
-- when changed), the errors that block saving them, the parsed buffer, and the problem of each
-- field. A missing or misplaced header blocks saving: the text around it would land in another
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
  local function mark(lnum, opts)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, 0, opts)
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
  vim.list_extend(lines, { "", SECTIONS[2].title, guides.prefix(1), "", SECTIONS[3].title })
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

-- Places <Tab> moves to: { lnum, kind = "value" | "text" }, the fields then the description
-- and the comment (the line under their header)
local function stops(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local headers = header_lnums(lines)
  local result = {}
  for lnum = 1, next_header(lines, 1) - 1 do
    if not is_title(lnum, lines[lnum]) and lines[lnum]:match("^%s*[^%s:][^:]*:") then
      table.insert(result, { lnum = lnum, kind = "value" })
    end
  end
  for _, key in ipairs({ "description", "comment" }) do
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

-- Whether the details split is open, showing a details buffer
local function details_open()
  return details_win and vim.api.nvim_win_is_valid(details_win)
    and buffers[vim.api.nvim_win_get_buf(details_win)] ~= nil
end

local function close()
  if details_open() then
    local origin = buffers[vim.api.nvim_win_get_buf(details_win)].origin
    -- The buffer is only hidden (bufhidden=hide): its edits survive
    pcall(vim.api.nvim_win_close, details_win, true)
    local win = origin and vim.api.nvim_buf_is_valid(origin) and vim.fn.bufwinid(origin)
    if win and win ~= -1 then
      vim.api.nvim_set_current_win(win)
    end
  end
  details_win = nil
end

local function show(bufnr)
  if details_open() then
    vim.api.nvim_set_current_win(details_win)
  else
    vim.cmd("vsplit")
    vim.cmd("wincmd L")
    details_win = vim.api.nvim_get_current_win()
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
    require("workhorse").refresh()
  end)
end

--- Confirm the changes of the details buffer `bufnr` (default: current), then send them.
--- `on_confirmed`, when given, runs once they are confirmed (or when there is nothing to apply)
function M.save(bufnr, on_confirmed)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = buffers[bufnr]
  if not state then
    return
  end
  if state.saving then
    notify("Wait for the save to finish", vim.log.levels.WARN)
    return
  end
  local changes, errors = detect(bufnr)
  if #errors > 0 then
    notify(table.concat(errors, "\n"), vim.log.levels.WARN)
    return
  end
  if not next(changes) then
    vim.bo[bufnr].modified = false
    notify("No changes to apply")
    if on_confirmed then
      on_confirmed()
    end
    return
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
  require("workhorse.ui.list_confirm").show(("Changes to #%d"):format(item.id), entries, function(confirmed)
    if not confirmed then
      return
    end
    if on_confirmed then
      on_confirmed()
    end
    state.saving = true
    local done = require("workhorse.progress").start("Saving #" .. item.id)
    workitems.update_fields(item.id, fields, function(_, err)
      if err then
        state.saving = false
        done(true)
        notify(("Failed to update #%d: %s"):format(item.id, tostring(err)), vim.log.levels.ERROR)
        return
      end
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
        end
        refresh_origin(state.origin)
      end)
    end, column_field)
  end)
end

--- Load the work item again, asking first when there are unsaved changes
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
  map("<leader><leader>", function()
    M.save(bufnr)
  end, "apply the changes")
  map("<leader>R", function()
    M.reload(bufnr)
  end, "reload the work item")
  -- With changes, confirm and apply them first: the save goes on with the buffer hidden, and a
  -- failed one leaves its edits there
  map("<CR>", function()
    if vim.bo[bufnr].modified then
      M.save(bufnr, close)
    else
      close()
    end
  end, "apply the changes and close the details")
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
    -- A line still without its ":" completes the key
    start = function(line)
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

--- Open the details of `work_item` in the split on the right (closing it when it already shows
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
