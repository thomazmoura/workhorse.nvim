-- Type-to-confirm of a deletion: the user types the name of what is deleted, and only that name
-- (case aside) confirms it.
local M = {}

-- What input() returns on <Esc>: a control character nobody types into a name
local CANCELLED = "\1"

--- Ask to type `name` after `prompt`: true when it was typed (case aside), false on anything
--- else, nil when cancelled (<Esc> or <C-c>)
function M.ask(prompt, name)
  local ok, typed = pcall(vim.fn.input, { prompt = prompt, cancelreturn = CANCELLED })
  -- Clear the prompt from the command line before what follows
  vim.cmd("redraw")
  if not ok or typed == CANCELLED then
    return nil
  end
  return vim.fn.tolower(typed) == vim.fn.tolower(name)
end

return M
