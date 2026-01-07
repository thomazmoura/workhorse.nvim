# Changelog

All notable changes to workhorse.nvim are documented in this file.

## [Unreleased]

### Added
- Board Column grouping mode: display work items grouped by Kanban board columns instead of workflow states
- Stack Rank ordering: items within each column are sorted by their Stack Rank (same order as the board)
- New configuration options: `team`, `grouping_mode`, `default_board`, `column_colors`
- New API module for fetching board column definitions (`api/boards.lua`)
- Support for moving work items between board columns by dragging lines between sections

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
