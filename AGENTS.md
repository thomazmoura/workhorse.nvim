# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Workhorse.nvim is an Azure DevOps work item editor for Neovim inspired by oil.nvim. Work items are displayed as editable text lines grouped by state, allowing batch editing, state changes, and CRUD operations directly from a buffer.

## Architecture

### Core Layers

**API Layer** (`lua/workhorse/api/`)
- `client.lua` - HTTP client using plenary.curl with PAT-based Basic auth
- `workitems.lua` - Work item CRUD operations (create, update, delete, state change)
- `queries.lua` - Query execution and folder flattening
- `areas.lua` - Area/classification hierarchy fetching

**Buffer Management** (`lua/workhorse/buffer/`)
- `init.lua` - Buffer lifecycle, state tracking, keymap setup
- `render.lua` - Renders work items grouped by state with section headers
- `parser.lua` - Parses buffer lines back into structured data
- `changes.lua` - Detects differences between original and edited state

**UI Components** (`lua/workhorse/ui/`)
- `state_menu.lua` - Floating window for state selection
- `area_picker.lua` - Area selection dropdown
- `confirm.lua` - Confirmation dialog
- `choices.lua` - Dropdown-like completion of line values (build forms, repository screen; blink.cmp or native)
- `list_confirm.lua` - Confirmation float listing the changes of a save
- `type_name.lua` - Type-to-confirm of a deletion (the name must be typed, case aside)
- `menu.lua` - Fuzzy menu of the screens (`<leader>w/`, `:Workhorse menu`; Telescope or vim.ui.select)
- `picker.lua` - Shared fuzzy picker (Telescope or vim.ui.select), used by the menu and the `<M-/>` context search of each screen
- `header.lua` - Header of the editable lists (title, `<CR>` actions, `───── ◇ ─────` rule; empty lines with virtual text) and the shared rule
- `send.lua` - The send keys of every screen: `<leader><leader>` in normal mode (buffer-local, so it overrides the global save-all mapping), `<C-CR>` in insert mode only, `<CR>` in normal mode only on popup screens (the forms); `:w` does nothing (`ignore_write`). Every send asks first (`list_confirm` or `vim.fn.confirm` with `&Yes\n&No`): `y`/`<CR>` confirms, `n`/`<Esc>` cancels
- `pinned.lua` - Frozen headers: a copy of a screen's header (lines and extmarks) pinned in a float while it is scrolled away

**Repositories screen** (`lua/workhorse/repos_screen/`, `<leader>wG`; `<leader>wg` opens the screen of the repository of the working directory)
- `init.lua` + `list.lua` - Editable list of the project's repositories (rename, create, delete one confirmation each)
- `new_repo.lua` - "New repository" form (default branch, .gitignore and optional README.md: first commit through the pushes API)
- `repo.lua` - Screen of one repository, styled like the PR screen: "name" title (`<CR>` back to the list), a General, a Security and a Policies section (bold titles, rules drawn as virtual lines, content indented one level and dedented for the section modules; `{`/`}` between them), winbar, combined save
- `general.lua` - Repository settings as "key: value" lines (the default branch, completed from its branches)
- `security.lua` - Permissions as text (Git Repositories security namespace ACLs; well-known group aliases mapped to the real groups)
- `policies.lua` - Branch policies as text, diffed against the policy configurations
- API: `api/repositories.lua`, `api/security.lua`, `api/policies.lua`, `api/identities.lua`
- `identities.lua` - Encrypted identity cache (users and groups, via the members of Project Collection Valid Users)

**Git** (`lua/workhorse/git.lua`)
- `run` - git commands that may reach a remote, never prompting (`GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=never`, `SSH_ASKPASS_REQUIRE=never`, `ssh -o BatchMode=yes` unless an ssh command is configured, a new session without a tty); `access` explains a failure (SSH key not in the agent of `$SSH_AUTH_SOCK`, no agent, unknown host key)

**Pull requests** (`lua/workhorse/prs/`, `<leader>wp`)
- `init.lua` - List of a repository's pull requests and the screen of one (Overview and Changes tabs, rendered from the data with `builds/render.lua`)
- `reviewers.lua` / `work_items.lua` - Editable sections of the Overview of an active pull request (`name: required|optional` reviewers completed from the identity cache; `#id | title` linked work items completed from `prs.work_items_query` or the last query, typed ids looked up on InsertLeave). Their text is spliced into every render (`ctx.edits`), saved with `<leader><leader>` after a `list_confirm`
- `diff.lua` - Delta-style diffs of the Changes tab
- `new_pr.lua` - "New pull request" forms of the list (on `builds/form.lua`): `<leader>wn` (branches, title, optional work item) and `<leader>wN` (the Criar-PullRequest.ps1 flow in a clone: push, create linked to a work item, completion options with "PR <id>: <title>", auto-complete, optional approval). In a clone, the local source branch is compared with the remote's before the creation: push when ahead or only local, rebase when behind or diverged, each asked first (declined: create from the server's branch after asking, or fail when it is not there)
- Required and optional checks on the Overview: the policy evaluations of the pull request (`api/pullrequests.lua` `checks`), expired / failed build checks re-queued with `<leader>wq` (`requeue_check`)
- API: `api/pullrequests.lua` (reviewers, linked work items, branches, creation, checks), `api/workitems.lua` (`link_artifact` / `unlink_artifact`)

**Libraries screen** (`lua/workhorse/libraries_screen/`, `<leader>wl`, `:Workhorse libraries`)
- `init.lua` - Editable list of the project's variable groups (rename, delete one confirmation each; a new line opens a draft)
- `library.lua` - Screen of one library, styled like the repository screen: Variables, Pipelines and Security sections, winbar, combined save; a draft's first save creates it
- `variables.lua` - Variables as "name: value" lines (secrets shown empty: empty keeps them)
- `pipelines.lua` - Pipelines allowed to use the library (pipeline permissions, "Open access")
- `security.lua` - Roles (Reader, User, Administrator) per user and group (securityroles role assignments)
- API: `api/libraries.lua`

**Pipeline screen** (`lua/workhorse/pipeline_screen/`; the runs list of `builds/init.lua` is its first tab)
- `tabs.lua` - Runs │ Settings │ Variables tabs of one pipeline in the winbar, one buffer each (`<Tab>`/`<S-Tab>` normal mode, `g1`–`g3`, clickable)
- `init.lua` - Editable tab buffers (pipeline name as title, `<CR>` back to the runs, rule, pinned title, `list_confirm` save); one definition table per pipeline shared by both tabs
- `settings.lua` - The "New pipeline" form's fields as "Key: value" lines, completed and diffed against the definition (`[was X]`)
- `variables.lua` - Pipeline variables as `Name (secret, settable): value` lines (secrets empty: empty keeps them)
- Shared: `builds/definition_fields.lua` (fields, choices, hints and values of the form and the Settings tab), `ui/variable_lines.lua` (variable lines of the library Variables section and the Variables tab)
- API: `api/builds.lua` `get_definition_full`, `update_definition` (GET then PUT; `changes` may be a function changing the JSON)

**Work item details** (`lua/workhorse/buffer/details.lua`, `<CR>` on a work item)
- A popup (float); one hidden buffer per work item keeps its edits after the popup closes, `<leader><leader>`/`<C-CR>` send the pending changes of all of them in one confirmation (`<CR>` sends and closes the popup), and refreshing a query with pending details asks first (`details.pending` / `details.discard`)
- Column, Tags, Description, Attachments, Discussion Comment and Discussion History sections in one editable buffer
- Attachments: one file name per line, a link (`url` extmark: `gx`); a deleted line removes it, a new line (a path, or a
  file of the attachment folders: `attachments.lua`, shared with paperboy's `compose.attachment_dirs`) uploads it on save
- API: `api/workitems.lua` (`list_attachments`, `upload_attachment`, `update_attachments`; uploads go through
  `client.upload`, which hands curl the file itself)

### Data Flow

```
User edits buffer → parser.lua extracts items → changes.lua detects diffs
                                              → workitems.lua applies to API
```

### Buffer Format

Work items are rendered as:
```
══════════════ [State] ══════════════
[Type] #ID | Title
```

Change types detected: CREATED, UPDATED, DELETED, STATE_CHANGED (by moving lines between sections)

## Key Configuration

Environment variables:
- `AZURE_DEVOPS_URL` - Organization URL (e.g., https://dev.azure.com/org)
- The PAT has no environment variable nor `setup()` option: it is only read from `workhorse/pat` in the locksmith store

## Secrets and encrypted caches

`lua/workhorse/store.lua` wraps [locksmith.nvim](https://github.com/thomazmoura/locksmith.nvim)
(optional dependency, shared with paperboy.nvim): the PAT is the secret `workhorse/pat`, and the
repository and identity caches are locksmith caches of the `workhorse` namespace.

## Plugin Commands

- `:Workhorse query [id]` - Open saved query
- `:Workhorse apply` - Apply pending changes
- `:Workhorse state` - Change state of item under cursor
- `:Workhorse refresh` - Refresh from server (also `<leader>wr`, global: what `<leader>R` does in the current Workhorse buffer)
- `:Workhorse resume` - Reopen last query
- `:Workhorse menu` - Fuzzy menu of the screens (also `<leader>w/`)
- `:Workhorse repos list` - Repositories screen (also `<leader>wG`)
- `:Workhorse repos here` - Screen of the repository of the working directory (also `<leader>wg`)
- `:Workhorse identities refresh` - Update the identity cache
- `:Workhorse libraries` - Libraries (variable groups) screen (also `<leader>wl`)
- `:Workhorse pipelines settings [id]` / `:Workhorse pipelines variables [id]` - Settings / Variables tab of a pipeline

## Development Notes

- No build step required - pure Lua plugin
- No test framework currently in place
- plenary.nvim is a required dependency for HTTP client
- Telescope is optional but recommended for query picker

## Commit Guidelines

- **Do not mention Claude Code in commit messages** - Keep commit messages focused on the changes themselves
- After each commit, update `CHANGELOG.md` with:
  - Version: First 7 characters of the commit hash
  - Date: The commit date
  - Description of changes
- **Skip CHANGELOG updates for documentation-only commits** - Commits that only modify `CHANGELOG.md`, `README.md`, or `AGENTS.md` do not need a CHANGELOG entry (to avoid infinite amend loops)

## Documentation Guidelines

- Update `README.md` whenever a new feature or configuration option is added
- Keep the CHANGELOG.md in sync with commits
