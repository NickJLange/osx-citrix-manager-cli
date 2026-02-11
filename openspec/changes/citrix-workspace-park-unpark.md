# Citrix Workspace Park/Unpark for macOS

## Goal

Create a robust, idempotent script pair (`citrix-park.sh` / `citrix-unpark.sh`) that can safely stop ("park") all Citrix Workspace processes and launchd services — freeing CPU, memory, and battery — then cleanly restore ("unpark") them without requiring a reboot.

## Problem

Simply killing Citrix processes leaves the system in a broken state:
- XPC/Mach port registrations go stale
- `AuthManager` fails to reconnect ("Unable to connect to the citrix AuthManager service")
- KeepAlive plists respawn killed processes immediately
- A reboot is the only reliable recovery

## Research Summary

### Citrix Workspace Components on This System

**LaunchAgents** (user-level, `/Library/LaunchAgents/`):

| Label | RunAtLoad | KeepAlive | Role |
|-------|-----------|-----------|------|
| `com.citrix.ReceiverHelper` | Yes | SuccessfulExit | **Central hub** — 15 XPC/Mach services (auth, config, sessions, plugins, feature flags) |
| `com.citrix.ServiceRecords` | Yes | SuccessfulExit | Beacons & service records |
| `com.citrix.AuthManager_Mac` | No | No | Authentication XPC service |
| `com.citrix.safariadapter` | Yes | Crashed+SuccessfulExit | Safari browser integration |
| `com.citrix.WebLauncher` | Yes | Always | ICA file launch handler |
| `com.citrix.UninstallMonitor` | No | SuccessfulExit | WatchPaths on app bundle |
| `com.citrix.devicetrust.launchagent` | No | No | deviceTRUST posture (symlink, optional) |

**LaunchDaemons** (root-level, `/Library/LaunchDaemons/`):

| Label | Role |
|-------|------|
| `com.citrix.CtxWorkspaceHelperDaemon` | Root helper: utility, user defaults, restore, Rosetta, Enterprise Browser removal |
| `com.citrix.ctxworkspaceupdater` | Auto-updater |
| `com.citrix.ctxusbd` | USB device redirection |
| `com.citrix.ReceiverUninstallHelper` | Uninstall support daemon |

### Key Insights

1. **`launchctl bootout`/`bootstrap`** is the correct modern API (not `unload -w`)
2. **Never kill before bootout** — KeepAlive will respawn processes
3. **Dependency order matters**: user agents are clients of system daemons
4. **AuthManager lacks RunAtLoad** — must be explicitly `kickstart`-ed on reload
5. **Citrix KB CTX691439**: background elements MUST be enabled for CWA to function
6. **No kernel/system extensions** involved on this system (verified)

## Proposed Changes

### New Files

- `scripts/citrix-park.sh` — Idempotent unload script
- `scripts/citrix-unpark.sh` — Idempotent reload script

### `citrix-park.sh` — Unload Sequence

```
1. Quit Citrix Workspace app gracefully (osascript)
2. Wait for main app process to exit (poll, timeout 10s, then SIGTERM)
3. Bootout user LaunchAgents (edge → hub order):
   a. com.citrix.safariadapter
   b. com.citrix.WebLauncher
   c. com.citrix.AuthManager_Mac
   d. com.citrix.ServiceRecords
   e. com.citrix.UninstallMonitor
   f. com.citrix.devicetrust.launchagent  (optional/configurable)
   g. com.citrix.ReceiverHelper            (hub — last)
4. Bootout system LaunchDaemons (sudo):
   a. com.citrix.ctxworkspaceupdater
   b. com.citrix.ctxusbd
   c. com.citrix.CtxWorkspaceHelperDaemon
   d. com.citrix.ReceiverUninstallHelper
5. Best-effort pkill for any stragglers
6. Verify: ps aux | grep -i citrix && launchctl list | grep citrix
7. Report status
```

### `citrix-unpark.sh` — Reload Sequence

```
1. Bootstrap system LaunchDaemons (sudo, reverse order):
   a. com.citrix.ReceiverUninstallHelper
   b. com.citrix.CtxWorkspaceHelperDaemon
   c. com.citrix.ctxusbd
   d. com.citrix.ctxworkspaceupdater
2. Bootstrap user LaunchAgents (hub → edge order):
   a. com.citrix.ReceiverHelper             (hub — first)
   b. com.citrix.ServiceRecords
   c. com.citrix.AuthManager_Mac
   d. com.citrix.safariadapter
   e. com.citrix.WebLauncher
   f. com.citrix.UninstallMonitor
   g. com.citrix.devicetrust.launchagent   (optional/configurable)
3. Kickstart AuthManager_Mac (no RunAtLoad)
4. Optionally launch Citrix Workspace app
5. Verify: launchctl list | grep citrix && ps aux | grep -i citrix
6. Report status
```

### Script Design Principles

- **Idempotent**: treat "not loaded"/"not found" as non-fatal
- **UID-aware**: detect console user UID correctly (not $UID when run as root)
- **Verbose**: `--verbose` flag for debugging
- **Dry-run**: `--dry-run` flag to preview actions
- **Exit codes**: 0=success, 1=partial failure, 2=fatal error
- **Readiness check**: after unpark, poll `launchctl print` to confirm services are running before declaring success

## Verification

1. Run `citrix-park.sh` — verify zero Citrix processes in `ps aux`, zero entries in `launchctl list`
2. Run `citrix-unpark.sh` — verify all services restored
3. Open Citrix Workspace app — verify it connects without "AuthManager" errors
4. Repeat park/unpark cycle 3 times without reboot to confirm idempotency
5. Test from both interactive terminal and `sudo` contexts

## Risks

- **deviceTRUST**: stopping it may affect corporate posture checks beyond Citrix
- **Citrix updates**: future versions may add new agents/daemons; scripts should warn on unknown `com.citrix.*` entries
- **macOS version differences**: `launchctl bootout/bootstrap` semantics may vary; tested on macOS 15.7.1 (Sequoia)
