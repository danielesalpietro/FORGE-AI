#!/usr/bin/env bash
# =====================================================================
# FORGE-AI :: read and change a host's provisioning lifecycle state
# =====================================================================
#   ./scripts/set-boot-state.sh                       show every host
#   ./scripts/set-boot-state.sh poc-ubuntu-01         show one host
#   ./scripts/set-boot-state.sh poc-ubuntu-01 new     queue a reinstall
#   ./scripts/set-boot-state.sh --history poc-windows-01
#
# The state service decides what each MAC receives on its next network
# boot. Setting a host back to "new" is therefore how a rebuild is
# requested -- and it is destructive on an installed machine, so it asks.
#
#   new -> installing -> installed -> configuring -> ready
#            |                                         ^
#            +--> failed <-----------------------------+
#
# Exit codes: 0 ok, 1 rejected or unreachable, 2 usage error
# =====================================================================
set -Eeuo pipefail

export FORGE_SCRIPT_NAME="set-boot-state.sh"
# shellcheck source=bootstrap/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../bootstrap" && pwd)/lib/common.sh"
forge_enable_traps

readonly -a VALID_STATES=(new installing installed configuring ready failed)

SHOW_HISTORY=false
FORCE=false
TARGET=""
NEW_STATE=""

usage() {
    cat <<'USAGE'
Usage: ./scripts/set-boot-state.sh [TARGET] [STATE] [OPTIONS]

TARGET is a host name from config/poc.yml, or a MAC address in either
form (52:54:00:25:00:21 or 52-54-00-25-00-21). Omit it to list every
host.

STATE is one of: new installing installed configuring ready failed

Options:
  --history    show the full transition history
  --force      skip the confirmation when queueing a reinstall
  -h, --help   this message

Setting an installed host back to "new" queues a REINSTALL: its next
network boot will wipe the disk. That is why it asks first.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --history)  SHOW_HISTORY=true; shift ;;
        --force)    FORCE=true; shift ;;
        -h|--help)  usage; exit 0 ;;
        -*)         log_err "unknown option: $1"; usage; exit 2 ;;
        *)
            if [[ -z "$TARGET" ]]; then TARGET="$1"
            elif [[ -z "$NEW_STATE" ]]; then NEW_STATE="$1"
            else log_err "unexpected argument: $1"; usage; exit 2
            fi
            shift ;;
    esac
done

BASE_URL=""
STATE_TOKEN=""

setup() {
    forge_require_valid_config
    local gateway port
    gateway=$(forge_config '.control_plane.address')
    port=$(forge_config '.control_plane.boot_http_port')
    BASE_URL="http://${gateway}:${port}"

    # The token lives in the vault; read it if the vault is available.
    local vault="$FORGE_ROOT/ansible/inventories/poc/group_vars/all/vault.yml"
    if [[ -r "$vault" && -r "$FORGE_ROOT/.vault-password" ]] && command -v ansible-vault >/dev/null 2>&1; then
        STATE_TOKEN=$(ansible-vault view --vault-password-file "$FORGE_ROOT/.vault-password" "$vault" 2>/dev/null \
                      | sed -n 's/^vault_forge_state_token: *"\(.*\)"/\1/p' || true)
    fi
}

resolve_mac() {
    local target=$1
    if [[ "$target" =~ ^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$ ]]; then
        printf '%s' "${target,,}" | tr ':' '-'
        return 0
    fi
    local mac
    mac=$(forge_config ".hosts[] | select(.name == \"$target\") | .mac_address")
    if [[ -z "$mac" ]]; then
        log_err "'$target' is neither a MAC address nor a host in config/poc.yml"
        log_dim "configured hosts: $(forge_config '[.hosts[].name] | join(", ")')"
        exit 2
    fi
    printf '%s' "${mac,,}" | tr ':' '-'
}

state_colour() {
    case "$1" in
        ready)                 printf '%s' "$C_GREEN" ;;
        failed)                printf '%s' "$C_RED" ;;
        installing|configuring) printf '%s' "$C_YELLOW" ;;
        *)                     printf '%s' "$C_DIM" ;;
    esac
}

show_one() {
    local mac=$1
    local response
    if ! response=$(curl -fsS --max-time 10 "${BASE_URL}/api/state/${mac}" 2>&1); then
        log_err "the state service did not answer at ${BASE_URL}/api/state/${mac}"
        log_dim "is the control plane running?  docker compose ps state"
        exit 1
    fi

    local name state attempts updated
    name=$(printf '%s' "$response" | jq -r '.host // "unknown"')
    state=$(printf '%s' "$response" | jq -r '.state')
    attempts=$(printf '%s' "$response" | jq -r '.attempts // 0')
    updated=$(printf '%s' "$response" | jq -r '.updated_at // "never"')

    printf '  %-16s %-14s%s%-13s%s attempts=%-3s updated=%s\n' \
        "$name" "$mac" "$(state_colour "$state")" "$state" "$C_RESET" "$attempts" "$updated"

    if [[ "$SHOW_HISTORY" == true ]]; then
        printf '%s' "$response" | jq -r '
            .history // [] | .[] |
            "        \(.at)  \(.from // "-") -> \(.to // .event // "-")  (\(.source // "?"))\(if .detail != "" and .detail != null then "  \(.detail)" else "" end)"'
        printf '\n'
    fi
}

show_all() {
    log_step "Provisioning state"
    printf '\n' >&2
    local mac
    while read -r mac; do
        show_one "$mac"
    done < <(forge_config '.hosts[].mac_address' | tr ':' '-' | tr 'A-F' 'a-f')
    printf '\n' >&2

    local max_attempts
    max_attempts=$(forge_config '.pxe.max_install_attempts')
    log_dim "The state service stops offering an installer after ${max_attempts} attempts."
    log_dim "That is the reinstall-loop guard: a host at the limit is parked as 'failed'."
    log_dim "Reset one with: $0 <host> new"
}

set_state() {
    local mac=$1 state=$2

    # shellcheck disable=SC2076
    if [[ ! " ${VALID_STATES[*]} " =~ " ${state} " ]]; then
        log_err "'$state' is not a valid state"
        log_dim "valid states: ${VALID_STATES[*]}"
        exit 2
    fi

    local current
    current=$(curl -fsS --max-time 10 "${BASE_URL}/api/state/${mac}" 2>/dev/null | jq -r '.state // "unknown"')
    local host_name
    host_name=$(forge_config ".hosts[] | select((.mac_address | ascii_downcase | gsub(\":\"; \"-\")) == \"$mac\") | .name")

    if [[ "$state" == "new" && "$current" != "new" && "$current" != "failed" ]]; then
        log_warn "${host_name:-$mac} is currently '${current}'"
        log_warn "setting it to 'new' queues a REINSTALL: its next network boot wipes the disk"
        if [[ "$FORCE" == false ]]; then
            confirm "Queue a reinstall of ${host_name:-$mac}?" || die "aborted"
        fi
    fi

    local -a headers=(-H 'Content-Type: application/json')
    [[ -n "$STATE_TOKEN" ]] && headers+=(-H "X-Forge-Token: ${STATE_TOKEN}")

    local body response status
    body=$(jq -nc --arg s "$state" --arg h "${host_name:-$mac}" --arg u "$(id -un)" \
        '{state: $s, source: "set-boot-state.sh", host: $h, detail: ("set by " + $u)}')

    response=$(curl -sS --max-time 10 -o /tmp/forge-state-response.$$ -w '%{http_code}' \
        -X POST "${headers[@]}" -d "$body" "${BASE_URL}/api/state/${mac}" 2>&1) || status="000"
    status="${response}"
    local payload; payload=$(cat "/tmp/forge-state-response.$$" 2>/dev/null || echo "")
    rm -f "/tmp/forge-state-response.$$"

    case "$status" in
        200)
            log_ok "${host_name:-$mac}: ${current} -> ${state}"
            [[ "$state" == "new" ]] && log_dim "the next network boot of this host will start an installation"
            ;;
        401)
            log_err "the state service rejected the request: missing or invalid token"
            log_dim "FORGE_STATE_TOKEN is set in compose/.env and must match vault_forge_state_token"
            exit 1 ;;
        409)
            log_err "the state service refused the transition ${current} -> ${state}"
            log_dim "$(printf '%s' "$payload" | jq -r '.error // .' 2>/dev/null || printf '%s' "$payload")"
            log_dim "the lifecycle only moves forward; use 'new' to restart it"
            exit 1 ;;
        *)
            log_err "unexpected response (HTTP ${status}) from the state service"
            log_dim "$payload"
            exit 1 ;;
    esac
}

main() {
    setup

    if [[ -z "$TARGET" ]]; then
        show_all
        exit 0
    fi

    local mac; mac=$(resolve_mac "$TARGET")

    if [[ -z "$NEW_STATE" ]]; then
        printf '\n' >&2
        show_one "$mac"
        printf '\n' >&2
        exit 0
    fi

    set_state "$mac" "$NEW_STATE"
}

main "$@"
