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
- `AZURE_DEVOPS_PAT` - Personal Access Token

## Plugin Commands

- `:Workhorse query [id]` - Open saved query
- `:Workhorse apply` - Apply pending changes
- `:Workhorse state` - Change state of item under cursor
- `:Workhorse refresh` - Refresh from server
- `:Workhorse resume` - Reopen last query

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
