# AGENTS.md — osx-citrix-manager-cli

## Project Overview

macOS CLI tool (`scripts/cwm.sh`) for safely parking and unparking Citrix Workspace using `launchctl bootout`/`bootstrap` in correct dependency order, avoiding the reboot required by naive process killing.

## Repository Structure

```
scripts/          # Shell scripts (cwm.sh is the main entry point)
openspec/
  specs/          # Living documentation of current system state
  changes/        # Active change proposals (SDD workflow)
```

## Development Workflow

This project follows **Spec-Driven Development (SDD)**:

1. Proposals go in `openspec/changes/`
2. Implementation follows approved proposals
3. Completed proposals archive to `openspec/specs/`

## Code Conventions

- **Shell**: Bash with `set -euo pipefail`
- **Style**: `_snake_case` for internal functions, `cmd_` prefix for commands
- **Logging**: `_log` for normal output, `_verb` for verbose, `_warn`/`_err` for diagnostics
- **Idempotency**: all operations must be safe to run repeatedly
- **Error handling**: treat "not loaded" / "not found" as non-fatal; never `set +e` globally

## Testing

Manual verification on macOS:

```bash
# Full cycle test
sudo ./scripts/cwm.sh stop
./scripts/cwm.sh status    # expect all unloaded, 0 processes
sudo ./scripts/cwm.sh start
./scripts/cwm.sh status    # expect all loaded
```

```bash
# Dry-run (no side effects)
sudo ./scripts/cwm.sh --dry-run stop
```

## Lint / Check

```bash
shellcheck scripts/cwm.sh
```
