# Changelog

All notable changes to workhorse.nvim are documented in this file.

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
