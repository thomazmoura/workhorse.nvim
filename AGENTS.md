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

**Repositories screen** (`lua/workhorse/repos_screen/`, `<leader>wg`)
- `init.lua` + `list.lua` - Editable list of the project's repositories (rename, create, delete one confirmation each)
- `new_repo.lua` - "New repository" form (default branch, .gitignore and optional README.md: first commit through the pushes API)
- `repo.lua` - Screen of one repository: one buffer with a Security and a Policies section (`{`/`}` between them), winbar, combined save
- `security.lua` - Permissions as text (Git Repositories security namespace ACLs; well-known group aliases mapped to the real groups)
- `policies.lua` - Branch policies as text, diffed against the policy configurations
- API: `api/repositories.lua`, `api/security.lua`, `api/policies.lua`, `api/identities.lua`
- `identities.lua` - Encrypted identity cache (users and groups, via the members of Project Collection Valid Users)

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
- `AZURE_DEVOPS_PAT` - Personal Access Token (optional: otherwise `workhorse/pat` from the locksmith store)

## Secrets and encrypted caches

`lua/workhorse/store.lua` wraps [locksmith.nvim](https://github.com/thomazmoura/locksmith.nvim)
(optional dependency, shared with paperboy.nvim): the PAT is the secret `workhorse/pat`, and the
repository and identity caches are locksmith caches of the `workhorse` namespace.

## Plugin Commands

- `:Workhorse query [id]` - Open saved query
- `:Workhorse apply` - Apply pending changes
- `:Workhorse state` - Change state of item under cursor
- `:Workhorse refresh` - Refresh from server
- `:Workhorse resume` - Reopen last query
- `:Workhorse repos list` - Repositories screen (also `<leader>wg`)
- `:Workhorse identities refresh` - Update the identity cache

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
