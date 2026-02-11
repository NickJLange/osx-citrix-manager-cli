#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly APP_NAME="Citrix Workspace"
readonly APP_PATH="/Applications/Citrix Workspace.app"
readonly AGENTS_DIR="/Library/LaunchAgents"
readonly DAEMONS_DIR="/Library/LaunchDaemons"

VERBOSE=false
DRY_RUN=false

readonly AGENTS_STOP_ORDER=(
    com.citrix.safariadapter
    com.citrix.WebLauncher
    com.citrix.AuthManager_Mac
    com.citrix.ServiceRecords
    com.citrix.UninstallMonitor
    com.citrix.devicetrust.launchagent
    com.citrix.ReceiverHelper
)

readonly AGENTS_START_ORDER=(
    com.citrix.ReceiverHelper
    com.citrix.ServiceRecords
    com.citrix.AuthManager_Mac
    com.citrix.safariadapter
    com.citrix.WebLauncher
    com.citrix.UninstallMonitor
    com.citrix.devicetrust.launchagent
)

readonly DAEMONS_STOP_ORDER=(
    com.citrix.ctxworkspaceupdater
    com.citrix.ctxusbd
    com.citrix.CtxWorkspaceHelperDaemon
    com.citrix.ReceiverUninstallHelper
)

readonly DAEMONS_START_ORDER=(
    com.citrix.ReceiverUninstallHelper
    com.citrix.CtxWorkspaceHelperDaemon
    com.citrix.ctxusbd
    com.citrix.ctxworkspaceupdater
)

readonly KICKSTART_AGENTS=(
    com.citrix.AuthManager_Mac
)

# --- helpers ---

_log()  { printf '%s\n' "$*"; }
_verb() { $VERBOSE && printf '  %s\n' "$*" || true; }
_warn() { printf 'WARN: %s\n' "$*" >&2; }
_err()  { printf 'ERROR: %s\n' "$*" >&2; }

_get_console_uid() {
    local uid
    uid="$(id -u 2>/dev/null)"
    if [[ "$uid" == "0" ]]; then
        local user
        user="$(stat -f '%Su' /dev/console 2>/dev/null)" || user="$(scutil <<< 'show State:/Users/ConsoleUser' | awk '/Name :/ && !/loginwindow/ {print $3}')"
        uid="$(id -u "$user" 2>/dev/null)"
    fi
    echo "$uid"
}

_gui_domain() { echo "gui/$(_get_console_uid)"; }

_agent_is_loaded() {
    local label="$1"
    launchctl print "$(_gui_domain)/$label" &>/dev/null
}

_daemon_is_loaded() {
    local label="$1"
    sudo launchctl print "system/$label" &>/dev/null
}

_plist_exists() {
    local dir="$1" label="$2"
    [[ -e "$dir/$label.plist" ]]
}

_bootout_agent() {
    local label="$1"
    local domain
    domain="$(_gui_domain)"
    if ! _agent_is_loaded "$label"; then
        _verb "$label — already unloaded"
        return 0
    fi
    _log "  bootout $label"
    if $DRY_RUN; then return 0; fi
    if ! launchctl bootout "$domain/$label" 2>/dev/null; then
        _warn "bootout failed for $label (may already be gone)"
    fi
}

_bootout_daemon() {
    local label="$1"
    if ! _daemon_is_loaded "$label"; then
        _verb "$label — already unloaded"
        return 0
    fi
    _log "  bootout $label"
    if $DRY_RUN; then return 0; fi
    if ! sudo launchctl bootout "system/$label" 2>/dev/null; then
        _warn "bootout failed for $label (may already be gone)"
    fi
}

_bootstrap_agent() {
    local label="$1"
    local plist="$AGENTS_DIR/$label.plist"
    if ! _plist_exists "$AGENTS_DIR" "$label"; then
        _verb "$label — plist not found, skipping"
        return 0
    fi
    if _agent_is_loaded "$label"; then
        _verb "$label — already loaded"
        return 0
    fi
    _log "  bootstrap $label"
    if $DRY_RUN; then return 0; fi
    local domain
    domain="$(_gui_domain)"
    if ! launchctl bootstrap "$domain" "$plist" 2>/dev/null; then
        _warn "bootstrap failed for $label (may already be loaded)"
    fi
}

_bootstrap_daemon() {
    local label="$1"
    local plist="$DAEMONS_DIR/$label.plist"
    if ! _plist_exists "$DAEMONS_DIR" "$label"; then
        _verb "$label — plist not found, skipping"
        return 0
    fi
    if _daemon_is_loaded "$label"; then
        _verb "$label — already loaded"
        return 0
    fi
    _log "  bootstrap $label"
    if $DRY_RUN; then return 0; fi
    if ! sudo launchctl bootstrap system "$plist" 2>/dev/null; then
        _warn "bootstrap failed for $label (may already be loaded)"
    fi
}

_kickstart_agent() {
    local label="$1"
    local domain
    domain="$(_gui_domain)"
    _log "  kickstart $label"
    if $DRY_RUN; then return 0; fi
    if ! launchctl kickstart -k "$domain/$label" 2>/dev/null; then
        _warn "kickstart failed for $label"
    fi
}

_quit_app() {
    if ! pgrep -xq "Citrix Workspace"; then
        _verb "App not running"
        return 0
    fi
    _log "  Quitting $APP_NAME gracefully..."
    if $DRY_RUN; then return 0; fi
    osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true

    local waited=0
    while pgrep -xq "Citrix Workspace" && (( waited < 10 )); do
        sleep 1
        (( waited++ ))
    done

    if pgrep -xq "Citrix Workspace"; then
        _warn "App didn't quit gracefully, sending SIGTERM"
        pkill -x "Citrix Workspace" 2>/dev/null || true
        sleep 2
    fi
}

_kill_stragglers() {
    if $DRY_RUN; then return 0; fi
    local pids
    pids="$(pgrep -if citrix 2>/dev/null | grep -v "^$$\$" || true)"
    if [[ -n "$pids" ]]; then
        _warn "Killing straggler PIDs: $(echo $pids | tr '\n' ' ')"
        echo "$pids" | xargs kill 2>/dev/null || true
        sleep 2
        pids="$(pgrep -if citrix 2>/dev/null | grep -v "^$$\$" || true)"
        if [[ -n "$pids" ]]; then
            _warn "Force-killing remaining PIDs: $(echo $pids | tr '\n' ' ')"
            echo "$pids" | xargs kill -9 2>/dev/null || true
        fi
    fi
}

# --- commands ---

cmd_stop() {
    _log "Stopping $APP_NAME..."

    _log "Phase 1: Quit application"
    _quit_app

    _log "Phase 2: Bootout user LaunchAgents (edge → hub)"
    for label in "${AGENTS_STOP_ORDER[@]}"; do
        _bootout_agent "$label"
    done

    _log "Phase 3: Bootout system LaunchDaemons"
    for label in "${DAEMONS_STOP_ORDER[@]}"; do
        _bootout_daemon "$label"
    done

    _log "Phase 4: Cleanup stragglers"
    _kill_stragglers

    _log "Stop complete."
    echo
    cmd_status
}

cmd_start() {
    _log "Starting $APP_NAME..."

    _log "Phase 1: Bootstrap system LaunchDaemons"
    for label in "${DAEMONS_START_ORDER[@]}"; do
        _bootstrap_daemon "$label"
    done

    _log "Phase 2: Bootstrap user LaunchAgents (hub → edge)"
    for label in "${AGENTS_START_ORDER[@]}"; do
        _bootstrap_agent "$label"
    done

    _log "Phase 3: Kickstart on-demand agents"
    sleep 1
    for label in "${KICKSTART_AGENTS[@]}"; do
        _kickstart_agent "$label"
    done

    _log "Phase 4: Launch application"
    if $DRY_RUN; then
        _log "  (dry-run) open $APP_PATH"
    else
        open "$APP_PATH" 2>/dev/null || _warn "Could not launch $APP_NAME"
    fi

    sleep 2
    _log "Start complete."
    echo
    cmd_status
}

cmd_status() {
    _log "=== Citrix Workspace Status ==="

    local proc_count
    proc_count="$(pgrep -if citrix 2>/dev/null | wc -l | tr -d ' ')"
    _log "Running processes: $proc_count"
    if (( proc_count > 0 )); then
        ps aux | grep -i citrix | grep -v grep | grep -v "$SCRIPT_NAME" | awk '{printf "  PID %-8s CPU %-6s MEM %-6s %s\n", $2, $3, $4, substr($0, index($0,$11))}' || true
    fi

    echo
    _log "LaunchAgents:"
    for label in "${AGENTS_START_ORDER[@]}"; do
        if _agent_is_loaded "$label"; then
            printf '  %-45s %s\n' "$label" "LOADED"
        else
            printf '  %-45s %s\n' "$label" "unloaded"
        fi
    done

    echo
    _log "LaunchDaemons:"
    for label in "${DAEMONS_START_ORDER[@]}"; do
        if _daemon_is_loaded "$label"; then
            printf '  %-45s %s\n' "$label" "LOADED"
        else
            printf '  %-45s %s\n' "$label" "unloaded"
        fi
    done

    local unknown=""
    while IFS= read -r l; do
        [[ -z "$l" ]] && continue
        local found=false
        for known in "${AGENTS_START_ORDER[@]}" "${DAEMONS_START_ORDER[@]}"; do
            if [[ "$l" == "$known" ]]; then found=true; break; fi
        done
        [[ "$l" == application.com.citrix.* ]] && found=true
        $found || unknown+="  $l"$'\n'
    done < <(launchctl list 2>/dev/null | grep -i citrix | awk '{print $3}')
    if [[ -n "$unknown" ]]; then
        echo
        _warn "Unknown Citrix services detected:"
        printf '%s' "$unknown"
    fi
}

# --- main ---

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [options] <command>

Commands:
  start     Load all Citrix services and launch the app
  stop      Gracefully quit the app and unload all services
  status    Show current state of all Citrix components

Options:
  --verbose   Show detailed output
  --dry-run   Preview actions without executing
  -h|--help   Show this help
EOF
}

main() {
    local cmd=""

    while (( $# )); do
        case "$1" in
            --verbose) VERBOSE=true ;;
            --dry-run) DRY_RUN=true; VERBOSE=true ;;
            -h|--help) usage; exit 0 ;;
            start|stop|status) cmd="$1" ;;
            *) _err "Unknown argument: $1"; usage; exit 2 ;;
        esac
        shift
    done

    if [[ -z "$cmd" ]]; then
        usage
        exit 2
    fi

    if [[ ! -d "$APP_PATH" ]]; then
        _err "$APP_NAME not found at $APP_PATH"
        exit 2
    fi

    "cmd_$cmd"
}

main "$@"
