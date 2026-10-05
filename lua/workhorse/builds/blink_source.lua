-- blink.cmp source for the build forms ("Run new build", "New pipeline"): the choices of a
-- field (a branch, a parameter with allowed values...). The form asks for them on every
-- keystroke, matched against the whole value typed so far (blink.cmp alone would match only
-- its last word, e.g. "C" of "DMZ C"), and only this source runs on those fields, so buffer
-- words and snippets stay out.
local M = {}

local ID = "workhorse_run"
local FILETYPE = "workhorse-run"

local Source = {}
Source.__index = Source

function M.new()
  return setmetatable({}, Source)
end

function Source:enabled()
  return require("workhorse.builds.form").choice_completion() ~= nil
end

function Source:get_completions(context, callback)
  local completion = require("workhorse.builds.form").choice_completion()
  local items = {}
  if completion then
    local line, col = context.cursor[1] - 1, context.cursor[2]
    for i, word in ipairs(completion.matches) do
      table.insert(items, {
        label = word,
        filterText = word,
        -- Keep the form's order (starting with the text, containing it, then fuzzy): blink.cmp
        -- sorts by its own score first, which these offsets outweigh
        sortText = ("%04d"):format(i),
        score_offset = (#completion.matches - i + 1) * 1000,
        kind = require("blink.cmp.types").CompletionItemKind.EnumMember,
        textEdit = {
          newText = word,
          range = { start = { line = line, character = completion.start }, ["end"] = { line = line, character = col } },
        },
      })
    end
  end
  callback({ items = items, is_incomplete_forward = true, is_incomplete_backward = true })
end

local registered = false

--- Register the source with blink.cmp (once); returns true when done
function M.register()
  if registered then
    return true
  end
  local blink = require("blink.cmp")
  local ok = pcall(blink.add_source_provider, ID, { name = "Workhorse", module = "workhorse.builds.blink_source" })
  if not ok then
    return false
  end
  local per_filetype = require("blink.cmp.config").sources.per_filetype
  if per_filetype[FILETYPE] == nil then
    -- Only the choices on fields that have them, the usual sources elsewhere
    per_filetype[FILETYPE] = function()
      if require("workhorse.builds.form").choice_completion() then
        return { ID }
      end
      return { inherit_defaults = true }
    end
  else
    -- The user configured the filetype: add to it
    blink.add_filetype_source(FILETYPE, ID)
  end
  registered = true
  return true
end

return M
