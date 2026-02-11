# Citrix Workspace Manager (`cwm`)

A macOS CLI tool to safely park and unpark Citrix Workspace without requiring a reboot.

## The Problem

Simply killing Citrix Workspace processes leaves macOS in a broken state:

- XPC/Mach port registrations go stale
- AuthManager fails to reconnect ("Unable to connect to the citrix AuthManager service")
- KeepAlive plists respawn killed processes immediately
- **A reboot becomes the only reliable recovery**

## The Solution

`cwm` uses `launchctl bootout`/`bootstrap` to cleanly unload and reload all Citrix services in the correct dependency order — no reboot required.

### Stop (Park)

Unloads services edge-to-hub: quits the app gracefully, boots out user LaunchAgents (peripherals first, ReceiverHelper hub last), then system LaunchDaemons, then cleans up stragglers.

### Start (Unpark)

Reloads services hub-to-edge: bootstraps system LaunchDaemons first, then user LaunchAgents (ReceiverHelper hub first), kickstarts AuthManager (which lacks RunAtLoad), then launches the app.

## Requirements

- macOS (tested on macOS 15.7.1 Sequoia)
- Citrix Workspace installed at `/Applications/Citrix Workspace.app`
- `sudo` access (required for system LaunchDaemons)

## Installation

### Via Homebrew (recommended)

```bash
brew tap 5L-Labs/citrix-cli
brew install citrix-workspace-manager
```

### Manual

```bash
git clone https://github.com/5L-Labs/osx-citrix-manager-cli.git
cd osx-citrix-manager-cli
chmod +x scripts/cwm.sh
```

## Usage

```bash
# Check current Citrix status
cwm status

# Stop (park) all Citrix services
sudo cwm stop

# Start (unpark) all Citrix services
sudo cwm start

# Preview what would happen without making changes
sudo cwm --dry-run stop

# Verbose output for debugging
sudo cwm --verbose start
```

## Commands

| Command  | Description |
|----------|-------------|
| `start`  | Bootstrap all Citrix services and launch the app |
| `stop`   | Gracefully quit the app and unload all services |
| `status` | Show current state of all Citrix components |

## Options

| Flag        | Description |
|-------------|-------------|
| `--verbose` | Show detailed output for each operation |
| `--dry-run` | Preview actions without executing (implies `--verbose`) |
| `-h, --help`| Show usage help |

## Managed Components

### LaunchAgents (user-level)

| Label | Role |
|-------|------|
| `com.citrix.ReceiverHelper` | Central hub — 15 XPC/Mach services |
| `com.citrix.ServiceRecords` | Beacons & service records |
| `com.citrix.AuthManager_Mac` | Authentication XPC service |
| `com.citrix.safariadapter` | Safari browser integration |
| `com.citrix.WebLauncher` | ICA file launch handler |
| `com.citrix.UninstallMonitor` | WatchPaths on app bundle |
| `com.citrix.devicetrust.launchagent` | deviceTRUST posture |

### LaunchDaemons (system-level)

| Label | Role |
|-------|------|
| `com.citrix.CtxWorkspaceHelperDaemon` | Root helper daemon |
| `com.citrix.ctxworkspaceupdater` | Auto-updater |
| `com.citrix.ctxusbd` | USB device redirection |
| `com.citrix.ReceiverUninstallHelper` | Uninstall support |

## Design Principles

- **Idempotent**: safe to run multiple times; "not loaded" / "not found" are non-fatal
- **UID-aware**: correctly detects the console user UID, even when run via `sudo`
- **Dependency-ordered**: services are stopped edge-to-hub and started hub-to-edge
- **Unknown service detection**: warns if new `com.citrix.*` services appear after a Citrix update

## License

Apache License 2.0 — see [LICENSE](LICENSE).
