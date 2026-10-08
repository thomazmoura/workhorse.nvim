local M = {}

local render = require("workhorse.builds.render")
local config = require("workhorse.config")

-- Diff of two file contents, drawn delta style into a builds-style view: the buffer holds the
-- code itself, line numbers are inline virtual text, added/removed lines get a background and
-- the changed words of a modified line a stronger one, over treesitter syntax colors.

local function split_lines(text)
  if not text or text == "" then
    return {}
  end
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  for i, line in ipairs(lines) do
    lines[i] = line:gsub("\r$", "")
  end
  return lines
end

-- Text for vim.diff: one line per entry, newline-terminated
local function join(lines)
  return #lines == 0 and "" or table.concat(lines, "\n") .. "\n"
end

-- Diff `old_text` against `new_text` (nil for a missing side: an added or deleted file):
-- { old, new = lines, added, removed, hunks = { { old_start, old_count, new_start, new_count,
-- rows = { { kind = "ctx"|"del"|"add", old, new, text, pair } } } } }. A "del"/"add" row with a
-- `pair` is the changed counterpart of the row at that index in `rows` (for word emphasis)
function M.compute(old_text, new_text)
  local old, new = split_lines(old_text), split_lines(new_text)
  local changes = vim.diff(join(old), join(new), { result_type = "indices", algorithm = "histogram" })
  local result = { old = old, new = new, added = 0, removed = 0, hunks = {} }
  if #changes == 0 then
    return result
  end
  local ctx = config.get().prs.diff_context

  -- Lines before each change on both sides (a pure insertion/deletion reports the line it follows)
  for _, c in ipairs(changes) do
    c.a_before = c[2] > 0 and c[1] - 1 or c[1]
    c.b_before = c[4] > 0 and c[3] - 1 or c[3]
    result.removed = result.removed + c[2]
    result.added = result.added + c[4]
  end

  -- Changes closer than two contexts apart share a hunk
  local groups, current = {}, nil
  for i, c in ipairs(changes) do
    local prev = changes[i - 1]
    if prev and c.a_before - (prev.a_before + prev[2]) <= 2 * ctx then
      table.insert(current, c)
    else
      current = { c }
      table.insert(groups, current)
    end
  end

  for _, group in ipairs(groups) do
    local rows = {}
    local function context(from, to, offset)
      for o = from, to do
        table.insert(rows, { kind = "ctx", old = o, new = o + offset, text = old[o] })
      end
    end
    local first = group[1]
    context(math.max(1, first.a_before - ctx + 1), first.a_before, first.b_before - first.a_before)
    for i, c in ipairs(group) do
      local dels = {}
      for o = c.a_before + 1, c.a_before + c[2] do
        table.insert(rows, { kind = "del", old = o, text = old[o] })
        table.insert(dels, #rows)
      end
      for k = 1, c[4] do
        local n = c.b_before + k
        table.insert(rows, { kind = "add", new = n, text = new[n], pair = dels[k] })
        if dels[k] then
          rows[dels[k]].pair = #rows
        end
      end
      local next_change = group[i + 1]
      local from = c.a_before + c[2] + 1
      local to = next_change and next_change.a_before or math.min(#old, from + ctx - 1)
      context(from, to, (c.b_before + c[4]) - (c.a_before + c[2]))
    end

    local hunk = { rows = rows, old_count = 0, new_count = 0 }
    for _, row in ipairs(rows) do
      if row.old then
        hunk.old_start = hunk.old_start or row.old
        hunk.old_count = hunk.old_count + 1
      end
      if row.new then
        hunk.new_start = hunk.new_start or row.new
        hunk.new_count = hunk.new_count + 1
      end
    end
    -- An empty side starts at the line it follows, as in unified diffs
    hunk.old_start = hunk.old_start or first.a_before
    hunk.new_start = hunk.new_start or first.b_before
    table.insert(result.hunks, hunk)
  end
  return result
end

-- Words, runs of spaces and single punctuation characters
local function tokenize(text)
  local tokens = {}
  local i = 1
  while i <= #text do
    local s, e = text:find("^[%w_]+", i)
    if not s then
      s, e = text:find("^%s+", i)
    end
    if not s then
      -- One UTF-8 character
      local byte = text:byte(i)
      local len = byte >= 0xF0 and 4 or byte >= 0xE0 and 3 or byte >= 0xC0 and 2 or 1
      s, e = i, math.min(#text, i + len - 1)
    end
    table.insert(tokens, { s = s, e = e, text = text:sub(s, e) })
    i = e + 1
  end
  return tokens
end

-- Byte ranges ({ start, end_exclusive }, 0-based) of the tokens of `a` and of `b` that differ.
-- Lines too different to read as an edit of each other get no emphasis (like delta)
function M.word_diff(a, b)
  if #a > 1000 or #b > 1000 then
    return {}, {}
  end
  local ta, tb = tokenize(a), tokenize(b)
  local function text_of(tokens)
    local parts = {}
    for _, t in ipairs(tokens) do
      -- Tokens never hold a newline, so each one is a line for vim.diff
      table.insert(parts, t.text)
    end
    return join(parts)
  end
  local changes = vim.diff(text_of(ta), text_of(tb), { result_type = "indices" })
  local ra, rb, changed_a, changed_b = {}, {}, 0, 0
  for _, c in ipairs(changes) do
    if c[2] > 0 then
      local s, e = ta[c[1]].s, ta[c[1] + c[2] - 1].e
      table.insert(ra, { s - 1, e })
      changed_a = changed_a + (e - s + 1)
    end
    if c[4] > 0 then
      local s, e = tb[c[3]].s, tb[c[3] + c[4] - 1].e
      table.insert(rb, { s - 1, e })
      changed_b = changed_b + (e - s + 1)
    end
  end
  if changed_a + changed_b > 0.6 * (#a + #b) then
    return {}, {}
  end
  return ra, rb
end

-- Treesitter highlights of a whole file, by 1-based line: { [lnum] = { { col, end_col, group } } }.
-- Empty when no parser is installed for the file's language or the file is too large
function M.syntax(path, lines)
  local spans = {}
  if #lines == 0 or #lines > config.get().prs.max_highlight_lines then
    return spans
  end
  local ok = pcall(function()
    local ft = vim.filetype.match({ filename = path })
    local lang = ft and vim.treesitter.language.get_lang(ft)
    if not lang or not vim.treesitter.language.add(lang) then
      return
    end
    local query = vim.treesitter.query.get(lang, "highlights")
    if not query then
      return
    end
    local text = table.concat(lines, "\n")
    local parser = vim.treesitter.get_string_parser(text, lang)
    local tree = parser:parse()[1]
    for id, node in query:iter_captures(tree:root(), text) do
      local name = query.captures[id]
      -- Captures starting with "_" are helpers of predicates, not highlights
      if name:sub(1, 1) ~= "_" and name ~= "spell" and name ~= "nospell" then
        local group = "@" .. name .. "." .. lang
        local sr, sc, er, ec = node:range()
        for row = sr, er do
          local line = lines[row + 1]
          if line then
            local from = row == sr and sc or 0
            local to = row == er and ec or #line
            if to > from then
              spans[row + 1] = spans[row + 1] or {}
              table.insert(spans[row + 1], { from, to, group })
            end
          end
        end
      end
    end
  end)
  return ok and spans or {}
end

local change_labels = {
  add = { "added", "WorkhorsePRApproved" },
  delete = { "deleted", "WorkhorsePRRejected" },
  rename = { "renamed", "WorkhorsePRWaiting" },
  edit = { "modified", "WorkhorseBuildMeta" },
}

-- Short label and highlight of a change type ("edit", "add", "rename, edit", ...)
function M.change_label(change_type)
  for key, label in pairs(change_labels) do
    if (change_type or ""):find(key, 1, true) then
      return label[1], label[2]
    end
  end
  return change_type or "", "WorkhorseBuildMeta"
end

local function comment_lines(thread, pad)
  local lines = {}
  local icon = vim.fn.nr2char(0xf41f) -- nf-oct-comment
  for i, c in ipairs(thread.comments) do
    if i > 3 then
      table.insert(lines, { { pad .. "  … " .. (#thread.comments - 3) .. " more", "WorkhorsePRComment" } })
      break
    end
    local first = (c.content:gsub("\r", "")):match("^[^\n]*")
    table.insert(lines, {
      { pad .. (i == 1 and (icon .. " ") or "  "), "WorkhorsePRComment" },
      { c.author .. ": ", "WorkhorsePRCommentAuthor" },
      { first, "WorkhorsePRComment" },
    })
  end
  return lines
end

local function add_virt_lines(view, lnum, lines)
  view.virt_lines = view.virt_lines or {}
  view.virt_lines[lnum] = view.virt_lines[lnum] or {}
  vim.list_extend(view.virt_lines[lnum], lines)
end

-- Append the diff of `file` ({ path, original_path, change_type, diff = M.compute(...), error })
-- to `view`. `threads` are the comment threads of the pull request: those on this file are
-- drawn under their line. Returns the line of the file header
function M.render(view, file, threads, width)
  view.line_hls = view.line_hls or {}
  view.inline = view.inline or {}

  render.add_line(view, { { "" } })
  local label, label_hl = M.change_label(file.change_type)
  local title = file.path:gsub("^/", "")
  if file.original_path and file.original_path ~= file.path then
    title = file.original_path:gsub("^/", "") .. " → " .. title
  end
  local diff = file.diff
  local counts = diff and { { "+" .. diff.added, "WorkhorsePRApproved" }, { " -" .. diff.removed, "WorkhorsePRRejected" } }
    or nil
  local header = render.add_line(view, { { title, "WorkhorsePRDiffFile" }, { "  " .. label, label_hl } },
    { kind = "file_header", file = file }, counts)
  -- Delta-like box line under the file name
  local rule = render.add_line(view, { { "" } }, { kind = "file_header", file = file })
  view.overlay[rule] = { { string.rep("─", math.max(width, 1)), "WorkhorsePRDiffFile" } }

  -- Threads on this file, by the line they are anchored to
  local by_new, by_old = {}, {}
  for _, t in ipairs(threads or {}) do
    if t.file_path == file.path then
      if t.right_line then
        by_new[t.right_line] = by_new[t.right_line] or {}
        table.insert(by_new[t.right_line], t)
      elseif t.left_line then
        by_old[t.left_line] = by_old[t.left_line] or {}
        table.insert(by_old[t.left_line], t)
      end
    end
  end

  if not diff then
    local message = file.error == "binary" and "Binary file"
      or file.error == "too_large" and "File too large to diff"
      or file.error and ("Failed to load: " .. file.error)
      or "Loading…"
    render.add_line(view, { { "  " .. message, "WorkhorseBuildMeta" } }, { kind = "file_header", file = file })
    return header
  end
  if #diff.hunks == 0 then
    render.add_line(view, { { "  No content changes", "WorkhorseBuildMeta" } }, { kind = "file_header", file = file })
  end

  local digits = #tostring(math.max(#diff.old, #diff.new, 1))
  local blank = string.rep(" ", digits)
  local pad = string.rep(" ", digits * 2 + 4)
  local old_syntax, new_syntax = M.syntax(file.path, diff.old), M.syntax(file.path, diff.new)
  local placed = {}

  for _, hunk in ipairs(diff.hunks) do
    render.add_line(view, {
      { string.format("@@ -%d,%d +%d,%d @@", hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count),
        "WorkhorsePRDiffHunk" },
    }, { kind = "hunk", file = file })
    -- Word emphasis of each del/add pair, by row index
    local emphasis = {}
    for i, row in ipairs(hunk.rows) do
      if row.kind == "del" and row.pair then
        emphasis[i], emphasis[row.pair] = M.word_diff(row.text, hunk.rows[row.pair].text)
      end
    end
    for i, row in ipairs(hunk.rows) do
      local lnum = render.add_line(view, { { row.text } },
        { kind = "diff_line", file = file, old = row.old, new = row.new })
      local sign, sign_hl = " ", "WorkhorsePRDiffLineNr"
      if row.kind == "del" then
        view.line_hls[lnum] = "WorkhorsePRDiffDelete"
        sign, sign_hl = "-", "WorkhorsePRRejected"
      elseif row.kind == "add" then
        view.line_hls[lnum] = "WorkhorsePRDiffAdd"
        sign, sign_hl = "+", "WorkhorsePRApproved"
      end
      view.inline[lnum] = {
        { (row.old and string.format("%" .. digits .. "d", row.old) or blank) .. " "
          .. (row.new and string.format("%" .. digits .. "d", row.new) or blank) .. " │", "WorkhorsePRDiffLineNr" },
        { sign .. " ", sign_hl },
      }
      local spans = row.kind == "del" and old_syntax[row.old] or new_syntax[row.new]
      for _, s in ipairs(spans or {}) do
        table.insert(view.hls, { lnum - 1, s[1], s[2], s[3] })
      end
      local emph_hl = row.kind == "del" and "WorkhorsePRDiffDeleteText" or "WorkhorsePRDiffAddText"
      for _, range in ipairs(emphasis[i] or {}) do
        table.insert(view.hls, { lnum - 1, range[1], range[2], emph_hl, 4200 })
      end
      -- Comment threads under the line they are on
      local here = (row.new and by_new[row.new]) or (row.kind == "del" and by_old[row.old]) or nil
      for _, t in ipairs(here or {}) do
        if not placed[t.id] then
          placed[t.id] = true
          add_virt_lines(view, lnum, comment_lines(t, pad))
        end
      end
    end
  end

  -- Threads on lines outside the hunks go under the file header
  for _, t in ipairs(threads or {}) do
    if t.file_path == file.path and not placed[t.id] then
      local where = t.right_line and (" (line " .. t.right_line .. ")") or ""
      local lines = comment_lines(t, "  ")
      table.insert(lines[1], { where, "WorkhorseBuildMeta" })
      add_virt_lines(view, rule, lines)
    end
  end
  return header
end

return M
