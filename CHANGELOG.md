# Changelog

All notable changes to workhorse.nvim are documented in this file.

## [3dab3f7] - 2026-03-03

### Fixed
- Description and tags side panels now correctly populate on every open — the root cause was `BufLeave` firing on the newly-created empty buffer during window setup (when `nvim_win_set_buf` replaces the buffer), which called `save_description_to_memory` and wrote `""` to the cache with `modified=true`, permanently blocking re-sync
- `current_item_id` is now cleared before `open_or_focus_windows()` so autocmds triggered during window creation hit the early-return guard instead of corrupting the cache
- `current_item_id` is also cleared at the end of `close_windows()` to prevent deferred `WinClosed`/`BufHidden` callbacks from writing stale content after the panel is torn down

## [4167e9e] - 2026-03-03

### Fixed
- Description and tags side panels now correctly populate on subsequent opens (cache was being poisoned by autocmds firing on the empty buffer during window creation)
- Tree buffer `refresh_buffer` now syncs side panel content with refreshed server data (matches flat buffer behavior)

## [c47a17c] - 2026-02-18

### Fixed
- Confirmation dialog now correctly shows description and tag changes (was reading from legacy empty module)
- After applying changes and refreshing, re-opening the description side panel no longer shows stale/empty content

### Removed
- Legacy `buffer/description.lua` module (fully superseded by `buffer/side_panels.lua`)

## [a161811] - 2026-01-20

### Fixed
- Tree buffer now respects `column_order` configuration (was only applied to flat buffer)

## [0f669ab] - 2026-01-20

### Added
- Buffer reuse for `:Workhorse query [id]`: reuses existing buffer if one already exists for the same query ID, switching to it and refreshing
- New buffer name format: `Workhorse|[QueryName]|[QueryId]` (query_id makes it unique)
- `find_by_query_id()` function in both buffer and buffer_tree modules
- `queries.get_info()` API function to fetch query metadata (name, path) by ID
- Auto-fetch query name when `:Workhorse query [id]` is called without a name

## [0e9dedc] - 2026-01-12

### Added
- `column_sorting` config option for per-column ordering in `board_column` mode
- `ClosedDate` field support for sorting completed columns by date

### Changed
- Flat board-column buffer can now override stack rank sorting per column

## [b5b1a7d] - 2026-01-12

### Added
- `column_order` config option for prioritizing board columns in `board_column` grouping mode
- Columns listed in `column_order` appear first, remaining columns from the API follow

## [ef315e7] - 2026-01-12

### Added
- Undo/redo support for column changes in tree buffer
- Column changes via menu (`<leader>ws`) can now be undone with `u` and redone with `Ctrl+r`

## [fb4c5a0] - 2026-01-10

### Fixed
- Fix TF401320 State validation error when updating board columns
- Now uses correct board-specific WEF field from Board API instead of scanning work item fields
- Multiple changes to same work item are now merged into single API request

### Added
- `debug` config option for verbose API logging
- `get_board()` API function returning full board configuration including column field name

## [1f024e3] - 2026-01-09

### Changed
- Pending column changes now show `[Original → New]` format in virtual text instead of just `[New]`
- Applies to both tree buffer and flat buffer

## [ef5a2ae] - 2026-01-09

### Fixed
- Tree buffer column coloring now uses item's own board_column (same as virtual text)

## [354ae8a] - 2026-01-09

### Added
- Column-based line coloring in tree buffer (text before `|` colored by board column)

## [b4d7a82] - 2026-01-09

### Added
- `default_new_state` config option for board_column mode item creation

### Fixed
- Update state when moving items between board columns using stateMappings
- Side panels now properly handle empty description/tags content without extra whitespace

## [888a81b] - 2026-01-09

### Added
- Side panels for editing work item description and tags (toggle with `<CR>`)
- Description panel (top) with HTML-to-text conversion
- Tags panel (bottom) with one tag per line editing
- Readonly headers in side panels with auto-restore protection
- `tag_title_colors` config option for coloring titles based on work item type and tags
- `System.Tags` field support in API layer
- `update_tags()` API function for saving tag changes

### Changed
- Tree buffer `<CR>` now toggles side panels (was: column menu)
- Tree buffer `<leader>ws` now opens column menu (was: `<leader>w`)
- Cursor auto-positions on line 2 (after headers) when opening side panels

## [3558b46] - 2026-01-08

### Fixed
- Fix parent tracking for chained new items in tree buffer (new items at increasing indentation levels now correctly reference each other as parents)
- Fix type inference for new items in tree buffer to use configurable type hierarchy
- Fix indentation detection to recognize whitespace-based indentation (spaces/tabs from `>` command) in addition to tree characters

### Added
- New `work_item_type_hierarchy` config option to define work item types by tree indentation level (default: `{ "Epic", "Feature", "User Story", "Task" }`)

### Changed
- `default_area_path` config now skips the area picker dialog when set (creates new items directly with the configured area)

## [47f2a02] - 2026-01-08

### Added
- Lualine integration for displaying current work item in statusline
- New `lualine` module with periodic query fetching
- Auto-starts when `WORKHORSE_LUALINE_QUERY_ID` environment variable is set
- Configurable refresh interval (default: 1 minute)

## [3d4a304] - 2026-01-08

### Added
- Board Column grouping for tree buffer (top-level items only)
- Stack Rank ordering for top-level and sibling items in tree buffer
- Stack Rank change detection using LCS algorithm

## [7a1a7f6] - 2026-01-07

### Added
- Tree of Work Items buffer type for hierarchical display of work items with parent-child relationships
- New `buffer_tree` module for tree-structured query rendering

## [fad09d1] - 2026-01-07

### Fixed
- Fix stack rank ordering to actually be applied

## [7c8f161] - 2026-01-07

### Fixed
- Fix card column movement by using the hidden editable field

## [4c109b4] - 2026-01-07

### Fixed
- Ignore work items returned by the query but that could not be rendered

## [67dbc67] - 2026-01-07

### Changed
- Move agent configuration to AGENTS.md

## [09274d6] - 2026-01-07

### Added
- Board Column grouping mode: display work items grouped by Kanban board columns instead of workflow states
- Stack Rank ordering: items within each column are sorted by their Stack Rank (same order as the board)
- New configuration options: `team`, `grouping_mode`, `default_board`, `column_colors`
- New API module for fetching board column definitions (`api/boards.lua`)
- Support for moving work items between board columns by dragging lines between sections

## [948283e] - 2026-01-07

### Added
- Documentation updates

## [e506a04] - 2026-01-07

### Changed
- Replace the choice menu with a side buffer for description editing

## [51bc64e] - 2026-01-07

### Added
- Add the choice of area for the new work-item to be created

## [ef6531f] - 2026-01-06

### Changed
- Include the work-item ID on the coloring

## [46fbe89] - 2026-01-06

### Added
- Add work-item type information and color coding for types

## [8b41560] - 2026-01-06

### Changed
- Make each state a different header

## [f83dd62] - 2026-01-06

### Fixed
- Created Workspace apply to avoid issues with auto-saving

## [2b92e32] - 2026-01-06

### Fixed
- Fix connection issues

## [712a895] - 2026-01-06

### Added
- Add MIT license

## [0b78efd] - 2026-01-06

### Added
- Initial commit: workhorse.nvim plugin
