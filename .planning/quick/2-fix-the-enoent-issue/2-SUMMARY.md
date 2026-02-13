---
phase: quick-2
plan: 2
status: complete
started: 2026-02-13T04:35:00Z
completed: 2026-02-13T04:45:00Z
commits: [0882aba]
---

# Quick Task 2: Fix the DETS backup test enoent issue

## What Changed

### test/support/dets_helpers.ex
- Added explicit `:dets.close/1` calls for all 10 DETS table names between GenServer termination and restart in `restart_dets_servers/0`
- Root cause: Erlang DETS ignores the `file:` argument in `open_file/2` if the table name is already registered. Previous test teardowns deleted backing files while names remained registered, causing subsequent tests to point at deleted paths.

### test/dets_backup_test.exs
- Updated table count assertions from 9 to 10 (repo_registry added in Phase 23)
- Updated retention test table list to include `:repo_registry`

## Decisions
- Force-close DETS tables between terminate and restart rather than in teardown (keeps teardown simple, handles the root cause at the right layer)

## Result
- 393 tests, 0 failures (was 1 failure in CI since test introduction)
- `mix compile --warnings-as-errors` passes
