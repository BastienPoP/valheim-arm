#!/bin/bash
# Start the Valheim dedicated server (official x86_64 Linux build) under Box64.
set -uo pipefail

SERVER_DIR="${SERVER_DIR:-/opt/valheim}"
DATA_DIR="${DATA_DIR:-/data}"
STEAMCMD_DIR="${STEAMCMD_DIR:-/opt/steamcmd}"
CONFIG_DIR="${DATA_DIR}/config"
EMU_RC="${CONFIG_DIR}/box64.rc"

# 896660 = "Valheim Dedicated Server" (what we download).
# 892970 = "Valheim" (what the Steam API expects in SteamAppId).
VALHEIM_SERVER_APPID=896660
VALHEIM_GAME_APPID=892970

server_pid=""

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# Strip leading and trailing whitespace without spawning a subprocess.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# 0. Can we write where we need to?
# ---------------------------------------------------------------------------
# The server runs as an unprivileged user. A bind-mounted host directory keeps
# the host's ownership, so one that belongs to root (or to another account) is
# simply not writable here. Checking first turns that into one clear line
# instead of a confusing failure several steps later.

check_writable() {
    local dir="$1" label="$2"
    mkdir -p "${dir}" 2>/dev/null
    if [ ! -d "${dir}" ] || ! { : > "${dir}/.write-test"; } 2>/dev/null; then
        log "ERROR: ${dir} (${label}) is not writable as uid $(id -u):$(id -g)."
        log ""
        log "       This server does NOT run as root. If you are upgrading from an"
        log "       image that did, the directory still belongs to root. On the host:"
        log ""
        log "         sudo chown -R $(id -u):$(id -g) <the directory mounted here>"
        log ""
        log "       Under rootless Podman, map your own account into the container"
        log "       instead, and leave the ownership alone:  UserNS=keep-id"
        exit 1
    fi
    rm -f "${dir}/.write-test"
}

check_writable "${DATA_DIR}" "DATA_DIR"
check_writable "${SERVER_DIR}" "SERVER_DIR"

# ---------------------------------------------------------------------------
# 1. Emulator settings
# ---------------------------------------------------------------------------
# A BOX64_* variable already present in the environment (docker run -e,
# compose environment:) wins over the file: the file only covers what has not
# already been pinned at the container level.

load_box64_rc() {
    mkdir -p "${CONFIG_DIR}"
    if [ ! -f "${EMU_RC}" ]; then
        log "No Box64 settings found, copying the template to ${EMU_RC}"
        cp /opt/defaults/box64.rc.example "${EMU_RC}"
    fi

    local line name value
    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line%%#*}"
        line="$(trim "${line}")"
        [ -z "${line}" ] && continue
        case "${line}" in
            BOX64_*=*) ;;
            *) continue ;;
        esac
        name="${line%%=*}"
        value="$(trim "${line#*=}")"
        if [ -n "${!name+x}" ]; then
            log "  ${name}=${!name} (environment, ${EMU_RC} ignored)"
        else
            export "${name}=${value}"
            log "  ${name}=${value} (${EMU_RC})"
        fi
    done < "${EMU_RC}"

    # Settings that come from the environment only, so that the log shows the
    # complete configuration at start-up.
    local v
    for v in $(compgen -v | grep '^BOX64_' | sort); do
        grep -qE "^[[:space:]]*${v}=" "${EMU_RC}" 2>/dev/null && continue
        log "  ${v}=${!v} (environment)"
    done
}

log "Emulator settings"
load_box64_rc
box64 -v 2>&1 | head -1
log "Kernel: $(uname -r)  --  CPU: $(nproc) cores"

# ---------------------------------------------------------------------------
# 2. Download / update the server
# ---------------------------------------------------------------------------

mkdir -p "${SERVER_DIR}" "${DATA_DIR}"

# Box64 is invoked on the SteamCMD BINARY, never on steamcmd.sh: given a script
# it re-execs natively, and the x86 binary is then not emulated at all.
# The 64-bit binary has been present since the bootstrap done at build time.
STEAMCMD_LOG="$(mktemp)"
trap 'rm -f "${STEAMCMD_LOG}"' EXIT

run_steamcmd() {
    local exe ldp attempt=0 rc=0
    # "validate" re-checks the 2 GB of game files on every start. It is what
    # repairs a damaged install, but it makes start-up longer.
    local -a update_args=( "${VALHEIM_SERVER_APPID}" )
    [ "${STEAM_VALIDATE:-true}" = "true" ] && update_args+=( validate )
    if [ -x "${STEAMCMD_DIR}/linux64/steamcmd" ]; then
        exe="${STEAMCMD_DIR}/linux64/steamcmd"
        ldp="${STEAMCMD_DIR}/linux64"
    else
        exe="${STEAMCMD_DIR}/linux32/steamcmd"
        ldp="${STEAMCMD_DIR}/linux32"
    fi
    log "SteamCMD: ${exe}"
    while [ "${attempt}" -lt 3 ]; do
        attempt=$(( attempt + 1 ))
        # +app_info_update 1 and +app_info_print are ESSENTIAL: without them
        # SteamCMD starts with an empty metadata cache and refuses to install
        # ("Missing configuration", or "state is 0x6 after update job", which
        # leaves the server stuck on an outdated version).
        # The VDF dump from app_info_print is filtered out, only progress remains.
        # Order matters: +force_install_dir BEFORE +login (otherwise SteamCMD
        # warns "Please use force_install_dir before logon!"), and
        # +app_info_update AFTER, since it requires being logged in.
        LD_LIBRARY_PATH="${ldp}:${LD_LIBRARY_PATH:-}" box64 "${exe}" \
            +@sSteamCmdForcePlatformType linux \
            +force_install_dir "${SERVER_DIR}" \
            +login anonymous \
            +app_info_update 1 \
            +app_info_print "${VALHEIM_SERVER_APPID}" \
            +app_update "${update_args[@]}" \
            +quit 2>&1 \
            | grep --line-buffered -vE '^[[:space:]]*("|\{|\})' \
            | tee "${STEAMCMD_LOG}"
        rc=${PIPESTATUS[0]}
        # 42: SteamCMD updated itself and asks to be run again.
        [ "${rc}" -ne 42 ] && break
        log "SteamCMD updated itself, restarting (${attempt}/3)"
    done
    return "${rc}"
}

# An install left behind by a few patches cannot update itself, and says so in a
# way that looks like a transient glitch while being permanent:
#
#   Update state (0x3) reconfiguring, progress: 0.00 (0 / 0)
#   Error! App '896660' state is 0x6 after update job.
#
# Steam refuses to hand an anonymous login the request code for a manifest that
# is no longer the branch's current one. Updating means diffing against the
# manifest currently installed -- which, once a patch has shipped, is exactly
# the manifest Steam will not serve. So every start fails the same way, forever,
# and the server keeps running an old build with only a warning in the log.
#
# Dropping the local manifest makes SteamCMD evaluate the current one from
# scratch instead of diffing from the refused one. "validate" then reuses the
# files already on disk, so this is a verification pass over the install rather
# than a fresh download of it.
recover_stale_install() {
    local manifest="${SERVER_DIR}/steamapps/appmanifest_${VALHEIM_SERVER_APPID}.acf"
    log "SteamCMD cannot update this install: Steam no longer serves the manifest"
    log "it is installed from, so there is nothing to compute an update against."
    log "Clearing the local install state and verifying against the current build."
    log "This takes a few minutes. Set STEAM_RESET_ON_FAILURE=false to skip it."
    rm -f "${manifest}"
    rm -rf "${SERVER_DIR}/steamapps/downloading/${VALHEIM_SERVER_APPID}"
    STEAM_VALIDATE=true run_steamcmd
}

if [ "${UPDATE_ON_START:-true}" = "true" ]; then
    log "SteamCMD: checking the server (app ${VALHEIM_SERVER_APPID}, Linux depot)"
    run_steamcmd
    steamcmd_rc=$?

    if [ "${steamcmd_rc}" -ne 0 ] \
       && [ "${STEAM_RESET_ON_FAILURE:-true}" = "true" ] \
       && grep -q "state is 0x6 after update job" "${STEAMCMD_LOG}" 2>/dev/null; then
        recover_stale_install
        steamcmd_rc=$?
    fi

    if [ "${steamcmd_rc}" -eq 0 ]; then
        log "SteamCMD finished"
    else
        log "WARNING: SteamCMD exited with code ${steamcmd_rc}"
        log "         The server will start on the build already installed."
    fi
else
    log "UPDATE_ON_START=false: skipping SteamCMD"
fi

if [ ! -x "${SERVER_DIR}/valheim_server.x86_64" ]; then
    log "ERROR: ${SERVER_DIR}/valheim_server.x86_64 is missing or not executable."
    log "       Restart with UPDATE_ON_START=true to download it."
    exit 1
fi

# Some Steam components look for steamclient.so at this location.
if [ -f "${STEAMCMD_DIR}/linux64/steamclient.so" ]; then
    mkdir -p "${HOME}/.steam/sdk64"
    ln -sf "${STEAMCMD_DIR}/linux64/steamclient.so" "${HOME}/.steam/sdk64/steamclient.so"
fi

# ---------------------------------------------------------------------------
# 3. Server arguments
# ---------------------------------------------------------------------------
# An empty variable means the argument is not passed. That is what protects the
# settings stored in the world (see SERVER_PRESET / SERVER_MODIFIERS).

args=( -nographics -batchmode )

add_arg() { [ -n "${2:-}" ] && args+=( "$1" "$2" ); return 0; }

add_arg -name        "${SERVER_NAME:-}"
add_arg -world       "${SERVER_WORLD:-}"
add_arg -password    "${SERVER_PASSWORD:-}"
add_arg -port        "${SERVER_PORT:-}"
add_arg -public      "${SERVER_PUBLIC:-}"
add_arg -savedir     "${DATA_DIR}"
add_arg -saveinterval "${SERVER_SAVE_INTERVAL:-}"
add_arg -backups     "${SERVER_BACKUPS:-}"
add_arg -backupshort "${SERVER_BACKUP_SHORT:-}"
add_arg -backuplong  "${SERVER_BACKUP_LONG:-}"
add_arg -instanceid  "${SERVER_INSTANCE_ID:-}"
add_arg -simulationdistance "${SERVER_SIMULATION_DISTANCE:-}"
add_arg -preset      "${SERVER_PRESET:-}"

# -modifier takes TWO tokens. Compact form here: "combat=hard,raids=none".
if [ -n "${SERVER_MODIFIERS:-}" ]; then
    IFS=',' read -ra _mods <<< "${SERVER_MODIFIERS}"
    for _m in "${_mods[@]}"; do
        _m="$(trim "${_m}")"
        [ -z "${_m}" ] && continue
        if [[ "${_m}" != *=* ]]; then
            log "WARNING: modifier \"${_m}\" ignored (expected form: key=value)"
            continue
        fi
        args+=( -modifier "$(trim "${_m%%=*}")" "$(trim "${_m#*=}")" )
    done
fi

# -setkey takes ONE token and can be repeated. Form here: "nomap,playerevents".
if [ -n "${SERVER_SET_KEYS:-}" ]; then
    IFS=',' read -ra _keys <<< "${SERVER_SET_KEYS}"
    for _k in "${_keys[@]}"; do
        _k="$(trim "${_k}")"
        [ -n "${_k}" ] && args+=( -setkey "${_k}" )
    done
fi

[ "${SERVER_RESET_MODIFIERS:-false}" = "true" ] && args+=( -resetmodifiers )
[ "${SERVER_CONSOLE:-false}" = "true" ] && args+=( -console )

if [ "${SERVER_CROSSPLAY:-false}" = "true" ]; then
    log "WARNING: crossplay is NOT SUPPORTED by this image and does not work."
    log "         libparty.so (PlayFab Party) fails to load under Box64, so the"
    log "         server will start but the join code is not expected to be issued."
    log "         See the Crossplay section of the README."
    args+=( -crossplay )
fi

# Escape hatch: anything not modelled above, split on whitespace.
if [ -n "${SERVER_EXTRA_ARGS:-}" ]; then
    # shellcheck disable=SC2206
    _extra=( ${SERVER_EXTRA_ARGS} )
    args+=( "${_extra[@]}" )
fi

if [ -n "${SERVER_PRESET:-}" ] || [ -n "${SERVER_MODIFIERS:-}" ]; then
    log "WARNING: -preset / -modifier overwrite the settings stored in the world."
fi

# The password is masked in the log.
_shown=()
_hide=0
for _a in "${args[@]}"; do
    if [ "${_hide}" = "1" ]; then _shown+=( "********" ); _hide=0; continue; fi
    [ "${_a}" = "-password" ] && _hide=1
    _shown+=( "${_a}" )
done
log "Arguments: ${_shown[*]}"

# ---------------------------------------------------------------------------
# 4. Launch
# ---------------------------------------------------------------------------

mkdir -p "${DATA_DIR}/logs"
LOG_FILE="${DATA_DIR}/logs/valheim_$(date '+%d-%m-%Y').log"

cd "${SERVER_DIR}" || exit 1
export LD_LIBRARY_PATH="${SERVER_DIR}/linux64:${LD_LIBRARY_PATH:-}"
export SteamAppId="${VALHEIM_GAME_APPID}"

# Clean shutdown: Valheim saves the world on SIGINT. A shutdown requested while
# the world is still loading does not complete: the server can only stop cleanly
# once "ZDOMan.LoadChunks done" has been printed.
shutdown() {
    log "Shutdown signal received, saving the world and stopping the server"
    [ -n "${server_pid}" ] && kill -INT "${server_pid}" 2>/dev/null
}
trap shutdown TERM INT

log "Starting the server -- the world is ready at \"ZDOMan.LoadChunks done\""
box64 ./valheim_server.x86_64 "${args[@]}" > >(tee -a "${LOG_FILE}") 2>&1 &
server_pid=$!

# wait is interrupted by the trap, so loop until the server has really exited.
rc=0
while kill -0 "${server_pid}" 2>/dev/null; do
    wait "${server_pid}"
    rc=$?
done

log "Server stopped (exit code ${rc})"
exit "${rc}"
