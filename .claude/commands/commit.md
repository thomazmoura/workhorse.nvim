---
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git add:*), Bash(git commit:*), Read, Edit
description: Create a git commit following project guidelines
---

## Project Commit Guidelines

From @AGENTS.md:
- **Do not mention Claude Code in commit messages** - No co-author lines or references
- After each commit, update `CHANGELOG.md` with:
  - Version: First 7 characters of the commit hash
  - Date: The commit date (YYYY-MM-DD format)
  - Description of changes
- **Skip CHANGELOG updates for documentation-only commits** - Commits that only modify `CHANGELOG.md`, `README.md`, or `AGENTS.md` do not need a CHANGELOG entry

## Current CHANGELOG format

@CHANGELOG.md

## Your Task

1. Run `git status` to see all untracked and modified files (never use `-uall` flag)
2. Run `git diff` to see both staged and unstaged changes
3. Run `git log --oneline -5` to see recent commit message style
4. Stage relevant files with `git add`
5. Create a commit with a clear, descriptive message (NO Claude Code co-author line)
6. Run `git status` after commit to verify success
7. Get the commit hash and date from `git log -1 --format="%h %cs"`
8. Update CHANGELOG.md:
   - Add new entry at the top (after the header) with format: `## [hash] - date`
   - Use appropriate section headers: `### Added`, `### Changed`, `### Fixed`, `### Removed`
   - Skip this step if commit only modifies documentation files (CHANGELOG.md, README.md, AGENTS.md)

$ARGUMENTS
