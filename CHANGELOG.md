# Changelog

All notable changes to workhorse.nvim are documented in this file.

## [c0b37d5] - 2026-10-07

### Added
- Folding in the work item tree and `:Workhorse pipelines list` buffers: items fold by indentation and every parent starts folded, showing what it hides (`⋯ 2/5 active` for work items, with `fold_inactive_states` not counted as active; `⋯ 3 pipelines` for folders). Folds you open or close stay so across a refresh, and following a work item opens the folds hiding it
- Work item tree: `<Space>` folds or unfolds the item under the cursor; `<CR>` unfolds a folded item and opens the description panels on an unfolded one
- Pipelines list: `<CR>` or `<Space>` on a folder folds or unfolds it
- Global keymap `<leader>wp` opens the pipelines list (`:Workhorse pipelines list`)

## [a91ed6a] - 2026-10-07

### Added
- Organize pipelines: `:Workhorse pipelines list` shows the project's pipelines as an editable tree of their folders (`Folder/` lines, `#ID | name` pipelines, indented with `tree_indent`). Saving (`:w`, `<leader><leader>`, `:Workhorse apply`) applies moves and renames right away (renaming a folder line moves everything under it), then opens the "New pipeline" form pre-filled with the name and folder for each new line (`q`/`<Esc>` skips it; created lines get their `#ID` without reloading the buffer), then deletes the removed pipelines after one confirmation listing them all. `<C-c>` on a form or the confirmation stops the rest of the save; pending changes show as hints at the end of their lines

### Changed
- The "New pipeline" form can be opened pre-filled and report back (created, skipped, cancelled), and `<C-c>` closes it; form specs can run `on_close` however the form is closed

## [2e7b47b] - 2026-10-06

### Added
- Run a build again: once a run completes, its run tree and log headers show `Run new` in place of the live watching line. `<CR>` on it (or `<leader>wr`; on the runs list, for the run under the cursor) opens the "Run new build" form pre-filled with that run's branch, runtime parameters and queue-time variables
- Rerun failed jobs: a failed run also shows `Rerun failed jobs` (orange, `WorkhorseBuildRetry`). `<CR>` on it (or `<leader>wf`) asks for confirmation, then starts a new attempt of the same run that reruns only the failed jobs, and watches it like a freshly queued run

## [475234f] - 2026-10-06

### Changed
- Live watching a build stops on the first step that failed and stays on its log, instead of following the post-job/cleanup steps that keep running after the failure to the last one

## [9e2f47a] - 2026-10-05

### Added
- Create YAML pipelines: `:Workhorse pipelines new` opens a form (like "Run new build") with the name (defaults to the repository's), folder, repository, branch, YAML file and agent queue. Typing in a field offers the existing pipeline folders, the project's Git repositories, the repository's branches, the `.yml`/`.yaml` files of the repository at the typed branch (the local git repository's until they load) and the agent queues; picking a repository fills in its default branch. `<CR>`, `<leader><leader>` or `:w` creates the pipeline after a confirmation, with its CI trigger following the YAML file, then opens its runs list

### Changed
- The completion, navigation and window code of the "Run new build" form moved to `builds/form.lua`, shared by both forms

## [69c3ee2] - 2026-10-05

### Changed
- `<CR>` accepts the confirmation when queuing a run from the "Run new build" form and when cancelling a build (it used to pick Cancel / Keep running); `<Esc>` still aborts

## [e963066] - 2026-10-05

### Changed
- Typing the branch in the "Run new build" form opens a menu of the repository's branches, like the parameters with allowed values; `<C-x><C-o>` is no longer needed
- Form choices also include fuzzy matches after the values starting with or containing the text (`fealog` finds `feature/login-page`), and the blink.cmp source keeps that order

## [72ea9aa] - 2026-10-04

### Added
- `<CR>` in normal mode queues the run from the "Run new build" form, alongside `<leader><leader>` and `:w`

## [ff887a6] - 2026-10-04

### Changed
- Build view headers (runs list, run tree and log) stay visible while scrolling through a non-focusable float pinned over the top of the window, like nvim-treesitter-context. The log view is a single buffer again, and the pinned copy shows the buffer's line numbers, ignores `winblend` and keeps the cursor from hiding under it
- Build windows hide the sign and fold columns

## [e7bf0ac] - 2026-10-03

### Added
- Run new builds: a `Run new build` line on the runs list, `<leader>wn` in build buffers or `:Workhorse builds new [id]` opens a form (float by default, `builds.run_form`) with the branch, the YAML runtime parameters and the variables settable at queue time. `<Tab>`/`<S-Tab>` move between values, `<C-x><C-o>` completes branches and allowed values, `<leader>R` reloads the parameters from the typed branch, and `<leader><leader>` or `:w` validates and queues the run after a confirmation, sending only changed values, then opens its run tree
- Runtime parameters are read from the pipeline's YAML file (Azure Repos) with a small built-in YAML reader; `object` parameters are edited as one line of JSON
- Cancel builds: a `Cancel build` header line on running builds, `<leader>wx` or `:Workhorse builds cancel`, after a confirmation; the line shows `Cancelling…` until the run stops

### Changed
- Opening a running build from the runs list (or a run just queued) enables live watching and jumps to the latest log; going back up from a log does not re-enable it. Disable with `builds.live_on_running = false`

## [4685137] - 2026-10-03

### Added
- Live watching for build views: every `builds.live_interval` ms (5s by default) the run tree and log views open the log of the latest step that has one, so a finished step hands over to the next on the following refresh. Stops once the run completes
- Toggle it with `<leader>wu` (in build buffers), `:Workhorse live`, or `<CR>` on the right-aligned `Live watching enabled/disabled` header line (`WorkhorseBuildLive`)
- Logs opened while live watching start with the cursor on the last line and keep following the tail

### Changed
- The log header is pinned in its own split above the log, so it stays visible while scrolling; its links and keymaps work from there. The log view no longer shows the `── ◇ ──` separator

### Fixed
- Opening logs of two steps with the same name (e.g. `Finalize Job` in different jobs) no longer fails with `E95: Buffer with this name already exists`

## [bc9fecf] - 2026-10-03

### Changed
- Stages, jobs and steps are now one collapsible run tree buffer: everything loads at once, collapsed to the stage level; `<CR>` or `<Space>` toggles the level below a stage or job and opens a step's log. The separate steps buffer is gone
- Run lines show `branch (date)  author  title` with per-section highlights (`WorkhorseBuildBranch`, `WorkhorseBuildDate`, `WorkhorseBuildAuthor`, `WorkhorseBuildMessage`)
- Every build buffer starts with a header: the pipeline name, a tree of the current path indented two spaces per level, and a markview-style `── ◇ ──` separator (`WorkhorseBuildSeparator`) followed by a blank line
- Status icons use Nerd Font circles: outlined for success/warning, solid for failure
- Titles and header names are trimmed with `…` to fit the window and recalculated on resize, without new requests

### Added
- Header lines are links back to their level (runs list, or the run tree with that stage/job revealed)
- `<Esc>` goes back to the previous level, like `-` and `<BS>`; going back lands on the item you came from
- The log view opens with the cursor on the first log line, below the header

## [a1860b5] - 2026-10-03

### Added
- Default global keymaps: `<leader>wb` opens the pipeline picker, `<leader>wB` reopens the last opened pipeline without the picker
- `:Workhorse resume-build` (alias `:Workhorse builds resume`) to reopen the last opened pipeline

### Changed
- The session file now stores the last query and the last pipeline side by side; saving one no longer overwrites the other

## [7a6e405] - 2026-10-03

### Added
- Pipeline build browsing: `:Workhorse builds` opens a Telescope picker of pipeline definitions (`:Workhorse builds <id>` opens one directly)
- Drill-down through read-only buffers: runs (with per-stage status icons filled in lazily) → stages/jobs → steps → step log; `<CR>` drills down, `-`/`<BS>` goes back, `gw` opens in the browser, `q` closes
- Views of in-progress runs auto-refresh; logs fetch only new lines and follow the tail
- New `builds` config section (`top`, `refresh_interval`, `strip_timestamps`, `max_concurrent`) and `WorkhorseBuild*`/`WorkhorseLog*` highlight groups
- `silent` request option on the API client to suppress error notifications while polling

## [c794e8b] - 2026-07-28

### Changed
- The post-refresh cursor jump is now skipped when the cursor has moved since the buffer was opened or the refresh started — navigating away while the request is in flight is treated as deliberate, so Workhorse no longer pulls you back to the remembered work item
- `cursor.focus`/`focus_deferred` take an optional `expected_line` guard and return the line they settled on; `cursor.capture` returns the cursor line alongside the id
- `refresh_buffer` on both buffer modules now takes a `focus` table (`{ id, expected_line }`) instead of a bare id

## [38f73ba] - 2026-07-28

### Added
- Cursor now follows the work item instead of the line number: opening another query places the cursor on the same work item in the newly loaded buffer when it is present there, including across tree/flat view types
- Refreshing (`<leader>R`, `:Workhorse refresh`, and the automatic refresh after applying changes) keeps the cursor on the work item it was on, even when re-rendering moves it to another section
- When a query already has an open buffer, the cursor jumps on the currently rendered content immediately and again after the refresh lands, in case the item moved
- New `workhorse.cursor` module (`capture`/`focus`/`focus_deferred`/`get_module`) plus `find_line_by_id` on both buffer modules

## [a28934a] - 2026-07-28

### Added
- `<CR>` in normal mode inside the description or tags panel closes both side panels (insert mode keeps its default behavior)

### Fixed
- Tags panel now uses `belowright split` so it always opens below the description panel and becomes the current window regardless of the user's `splitbelow` setting — previously both window ids could end up pointing at the same window

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
