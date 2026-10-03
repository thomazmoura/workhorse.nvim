-- Minimal YAML reader for the `parameters:` block of a pipeline file (runtime
-- parameters). It covers what parameter declarations use: block mappings and
-- sequences, quoted and plain scalars, flow lists/maps ([a, b], {k: v}) and
-- block scalars (| and >). Anchors, tags and multiple documents are not supported.
local M = {}

-- Key order of each parsed mapping (mapping -> list of keys), so values encode
-- back in the order they were declared
local key_order = setmetatable({}, { __mode = "k" })

local function new_map()
  local map = {}
  key_order[map] = {}
  return map
end

local function map_set(map, key, value)
  if map[key] == nil then
    table.insert(key_order[map], key)
  end
  -- JSON null is kept as vim.NIL, so the key is not lost
  map[key] = value == nil and vim.NIL or value
end

-- Remove a trailing comment (" #...") outside quotes
local function strip_comment(text)
  local quote
  for i = 1, #text do
    local c = text:sub(i, i)
    if quote then
      if c == quote then
        quote = nil
      end
    elseif c == "'" or c == '"' then
      quote = c
    elseif c == "#" and (i == 1 or text:sub(i - 1, i - 1):match("%s")) then
      return (text:sub(1, i - 1):gsub("%s+$", ""))
    end
  end
  return (text:gsub("%s+$", ""))
end

local function unquote(text)
  if text:match("^'.*'$") then
    return (text:sub(2, -2):gsub("''", "'"))
  end
  if text:match('^".*"$') then
    local escapes = { n = "\n", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
    return (text:sub(2, -2):gsub("\\(.)", function(c)
      return escapes[c] or ("\\" .. c)
    end))
  end
  return nil
end

-- Plain scalar: booleans, null and numbers are typed, everything else is a string
local function plain(text)
  local lower = text:lower()
  if lower == "true" then
    return true
  elseif lower == "false" then
    return false
  elseif text == "" or text == "~" or lower == "null" then
    return vim.NIL
  end
  return tonumber(text:match("^[-+]?%d+%.?%d*$") and text or nil) or text
end

-- Flow collection or scalar starting at `pos`; returns value, next position
local function parse_flow(text, pos)
  pos = text:find("%S", pos) or #text + 1
  local c = text:sub(pos, pos)
  if c == "[" or c == "{" then
    local is_map = c == "{"
    local result = is_map and new_map() or {}
    pos = pos + 1
    while true do
      pos = text:find("%S", pos) or #text + 1
      local ch = text:sub(pos, pos)
      if ch == "]" or ch == "}" then
        return result, pos + 1
      elseif ch == "" then
        error("unterminated flow collection")
      elseif ch == "," then
        pos = pos + 1
      elseif is_map then
        local key
        key, pos = parse_flow(text, pos)
        pos = text:find("%S", pos)
        if text:sub(pos, pos) == ":" then
          local value
          value, pos = parse_flow(text, pos + 1)
          map_set(result, tostring(key), value)
        else
          map_set(result, tostring(key), vim.NIL)
        end
      else
        local value
        value, pos = parse_flow(text, pos)
        table.insert(result, value)
      end
    end
  end
  if c == "'" or c == '"' then
    local i = pos + 1
    while i <= #text do
      local ch = text:sub(i, i)
      if c == '"' and ch == "\\" then
        i = i + 1
      elseif ch == c then
        if c == "'" and text:sub(i + 1, i + 1) == "'" then
          i = i + 1
        else
          break
        end
      end
      i = i + 1
    end
    return unquote(text:sub(pos, i)), i + 1
  end
  -- Plain scalar inside a flow collection ends at , ] } or ": "
  local stop = pos
  while stop <= #text do
    local ch = text:sub(stop, stop)
    if ch == "," or ch == "]" or ch == "}" or (ch == ":" and text:sub(stop + 1, stop + 1):match("^[%s]?$")) then
      break
    end
    stop = stop + 1
  end
  return plain(vim.trim(text:sub(pos, stop - 1))), stop
end

-- Value written on the same line as its key or dash
local function inline_value(text)
  local quoted = unquote(text)
  if quoted then
    return quoted
  end
  if text:match("^[%[{]") then
    return (parse_flow(text, 1))
  end
  return plain(text)
end

-- Split "key: value" (key possibly quoted); nil when the text is not a mapping entry
local function split_key(text)
  local key, rest
  local q = text:sub(1, 1)
  if q == "'" or q == '"' then
    local close = text:find(q .. "%s*:%f[%s%z]", 2)
    if not close then
      return nil
    end
    key = unquote(text:sub(1, close))
    rest = text:sub(close + 1):match("^%s*:(.*)$")
  else
    local colon = text:find(":%f[%s%z]")
    if not colon then
      return nil
    end
    key = vim.trim(text:sub(1, colon - 1))
    rest = text:sub(colon + 1)
  end
  return key, vim.trim(rest)
end

local Parser = {}
Parser.__index = Parser

local function new_parser(raw_lines)
  local lines = {}
  for i, raw in ipairs(raw_lines) do
    local indent = #raw:match("^ *")
    lines[i] = { raw = raw, indent = indent, text = strip_comment(raw:sub(indent + 1)) }
  end
  return setmetatable({ lines = lines }, Parser)
end

-- Index of the next line with content at or after `i`
function Parser:skip(i)
  while self.lines[i] and self.lines[i].text == "" do
    i = i + 1
  end
  return i
end

-- Block scalar (| or >) whose lines are indented deeper than `parent_indent`
function Parser:block_scalar(header, i, parent_indent)
  local folded = header:sub(1, 1) == ">"
  local keep = header:find("+", 1, true)
  local strip = header:find("-", 1, true)
  local body, indent = {}, nil
  while self.lines[i] do
    local raw = self.lines[i].raw
    if raw:match("^%s*$") then
      table.insert(body, "")
    else
      local line_indent = #raw:match("^ *")
      if line_indent <= parent_indent then
        break
      end
      indent = indent or line_indent
      table.insert(body, raw:sub(indent + 1))
    end
    i = i + 1
  end
  local trailing = 0
  while #body > 0 and body[#body] == "" do
    table.remove(body)
    trailing = trailing + 1
  end
  local text = table.concat(body, folded and " " or "\n")
  if keep then
    text = text .. string.rep("\n", trailing + 1)
  elseif not strip and #body > 0 then
    text = text .. "\n"
  end
  return text, i
end

-- Value of a key/dash whose inline text is `rest`, continuing on the lines after `i`
function Parser:value_after(rest, i, indent)
  if rest:match("^[|>]") then
    return self:block_scalar(rest, i + 1, indent)
  end
  if rest ~= "" then
    return inline_value(rest), i + 1
  end
  local next_i = self:skip(i + 1)
  local line = self.lines[next_i]
  -- Nested block, or a sequence at the key's own indent ("key:\n- a")
  if line and (line.indent > indent or (line.indent == indent and line.text:match("^%-%f[%s%z]"))) then
    return self:block(next_i, line.indent)
  end
  return vim.NIL, next_i
end

function Parser:sequence(i, indent)
  local result = {}
  i = self:skip(i)
  while self.lines[i] and self.lines[i].indent == indent and self.lines[i].text:match("^%-%f[%s%z]") do
    local line = self.lines[i]
    local after = line.text:sub(2)
    local rest = vim.trim(after)
    if rest == "" or rest:match("^[|>]") or not split_key(rest) then
      local value
      value, i = self:value_after(rest, i, indent)
      table.insert(result, value)
    else
      -- "- key: value": a mapping whose keys line up after the dash
      local offset = indent + 1 + #after:match("^ *")
      line.indent, line.text = offset, rest
      local value
      value, i = self:mapping(i, offset)
      table.insert(result, value)
    end
    i = self:skip(i)
  end
  return result, i
end

function Parser:mapping(i, indent)
  local result = new_map()
  i = self:skip(i)
  while self.lines[i] and self.lines[i].indent == indent and not self.lines[i].text:match("^%-%f[%s%z]") do
    local key, rest = split_key(self.lines[i].text)
    if not key then
      error("expected 'key: value' at line " .. i .. ": " .. self.lines[i].text)
    end
    local value
    value, i = self:value_after(rest, i, indent)
    map_set(result, key, value)
    i = self:skip(i)
  end
  return result, i
end

function Parser:block(i, indent)
  local line = self.lines[i]
  if line.text:match("^%-%f[%s%z]") then
    return self:sequence(i, indent)
  end
  if split_key(line.text) then
    return self:mapping(i, indent)
  end
  return inline_value(line.text), i + 1
end

-- Runtime parameter declarations of a pipeline file: a list of
-- { name, display_name, type, default, values }, with `default` nil when there is none.
-- Raises an error when the block cannot be read.
function M.parameters(text)
  local lines = vim.split((text:gsub("^\239\187\191", ""):gsub("\r", "")), "\n", { plain = true })
  -- The block runs from "parameters:" to the next top-level key
  local first, last
  for i, line in ipairs(lines) do
    if not first then
      if line:match("^parameters:") then
        first = i
      end
    elseif line:match("^[^%s#%-]") then
      break
    else
      last = i
    end
  end
  if not first then
    return {}
  end
  local parser = new_parser(vim.list_slice(lines, first, last or first))
  local block = parser:mapping(1, 0).parameters
  local result = {}
  for _, p in ipairs(type(block) == "table" and block or {}) do
    if type(p) == "table" and p.name then
      local default = p.default
      table.insert(result, {
        name = tostring(p.name),
        display_name = p.displayName ~= vim.NIL and p.displayName or nil,
        type = p.type ~= vim.NIL and p.type or "string",
        default = default,
        values = type(p.values) == "table" and p.values or nil,
      })
    end
  end
  return result
end

-- Encode a parsed value as single-line JSON, keeping the declared key order
function M.encode(value)
  if type(value) ~= "table" or value == vim.NIL then
    return vim.json.encode(value)
  end
  local keys = key_order[value]
  local parts = {}
  if keys then
    for _, key in ipairs(keys) do
      table.insert(parts, vim.json.encode(key) .. ":" .. M.encode(value[key]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  for _, item in ipairs(value) do
    table.insert(parts, M.encode(item))
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

return M
