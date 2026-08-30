#!/usr/bin/env bash
# =====================================================================
# FORGE-AI :: wait until a host accepts an SSH key login
# =====================================================================
#   ./scripts/wait-for-ssh.sh 192.168.250.21
#   ./scripts/wait-for-ssh.sh poc-ubuntu-01 --timeout 1200
#
# A port being open is not the same as a usable login: sshd answers on
# 22 long before the machine has finished its first boot. This waits for
# an actual authenticated command to succeed.
#
# Exit codes:
#   0  SSH works and the expected user can run a command
#   1  timed out
#   2  usage error
# =====================================================================
set -Eeuo pipefail

export FORGE_SCRIPT_NAME="wait-for-ssh.sh"
# shellcheck source=bootstrap/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../bootstrap" && pwd)/lib/common.sh"
forge_enable_traps

TARGET=""
TIMEOUT=900
INTERVAL=10
SSH_USER=""
SSH_KEY=""
EXPECT_HOSTNAME=""
QUIET=false

usage() {
    cat <<'USAGE'
Usage: ./scripts/wait-for-ssh.sh TARGET [OPTIONS]

TARGET is an IP address, or a host name from config/poc.yml (in which
case the address, user and key are resolved from the configuration).

Options:
  --timeout SECONDS    give up after this long          (default 900)
  --interval SECONDS   seconds between attempts         (default 10)
  --user USER          override the SSH user
  --key PATH           override the private key
  --expect-hostname H  also require `hostname` to return H
  --quiet              only report the final result
  -h, --help           this message

Exit codes:
  0  an authenticated command succeeded
  1  timed out
  2  usage error
USAGE
}

# --help must work without a target: a user reaching for it does not
# yet know what the target argument should be.
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "")        usage; exit 2 ;;
esac
TARGET="$1"; shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout)          TIMEOUT="${2:?}"; shift 2 ;;
        --interval)         INTERVAL="${2:?}"; shift 2 ;;
        --user)             SSH_USER="${2:?}"; shift 2 ;;
        --key)              SSH_KEY="${2:?}"; shift 2 ;;
        --expect-hostname)  EXPECT_HOSTNAME="${2:?}"; shift 2 ;;
        --quiet)            QUIET=true; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)                  log_err "unknown option: $1"; usage; exit 2 ;;
    esac
done

say() { [[ "$QUIET" == true ]] || "$@"; }

# ---------------------------------------------------------------------
# Resolve the target from the configuration when it is a host name.
# ---------------------------------------------------------------------
resolve_target() {
    if [[ "$TARGET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        ADDRESS="$TARGET"
    else
        ADDRESS=$(forge_config ".hosts[] | select(.name == \"$TARGET\") | .ip_address")
        if [[ -z "$ADDRESS" ]]; then
            log_err "'$TARGET' is neither an IPv4 address nor a host in config/poc.yml"
            log_dim "configured hosts: $(forge_config '[.hosts[].name] | join(", ")')"
            exit 2
        fi
        [[ -z "$EXPECT_HOSTNAME" ]] && EXPECT_HOSTNAME="$TARGET"
    fi

    [[ -n "$SSH_USER" ]] || SSH_USER=$(forge_config '.users.automation_user')
    [[ -n "$SSH_USER" ]] || SSH_USER="forgeops"

    if [[ -z "$SSH_KEY" ]]; then
        SSH_KEY="${FORGE_SSH_KEY:-$HOME/.ssh/forge-ai-poc}"
    fi
}

readonly -a SSH_OPTIONS=(
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=8
    -o LogLevel=ERROR
    -o PreferredAuthentications=publickey
)

attempt() {
    local output
    if output=$(ssh "${SSH_OPTIONS[@]}" -i "$SSH_KEY" \
                    "${SSH_USER}@${ADDRESS}" 'hostname; id -un' 2>&1); then
        printf '%s' "$output"
        return 0
    fi
    LAST_ERROR="$output"
    return 1
}

diagnose() {
    # A timeout is only useful if it says which layer failed.
    printf '\n' >&2
    log_err "timed out after ${TIMEOUT}s waiting for SSH on ${ADDRESS}"
    printf '\n' >&2

    if ping -c 2 -W 2 "$ADDRESS" >/dev/null 2>&1; then
        log_ok "ICMP: $ADDRESS responds"
    else
        log_err "ICMP: $ADDRESS does not respond"
        log_dim "the VM may still be installing, or may not have got a DHCP lease"
        log_dim "  virsh list --all"
        log_dim "  virsh net-dhcp-leases $(forge_config '.provisioning_network.name' 2>/dev/null || echo gitops-provisioning)"
        log_dim "  curl -s $(forge_config '.control_plane.address' 2>/dev/null || echo 192.168.250.1):8080/api/state | jq"
    fi

    if timeout 5 bash -c "printf '' > /dev/tcp/${ADDRESS}/22" 2>/dev/null; then
        log_ok "TCP: port 22 is open"
        log_err "but authentication did not succeed"
        log_dim "last error: ${LAST_ERROR:-none recorded}"
        log_dim "the usual cause is the wrong key: expected $SSH_KEY to match"
        log_dim "security.ssh_authorized_keys in config/poc.yml"
        log_dim "  ssh-keygen -lf ${SSH_KEY}.pub"
    else
        log_err "TCP: port 22 is closed or filtered"
        log_dim "sshd may not have started, or ufw may be blocking this source address"
        log_dim "watch the installation: virsh console $(forge_config ".hosts[] | select(.ip_address == \"$ADDRESS\") | .name" 2>/dev/null || echo '<domain>')"
    fi

    printf '\n' >&2
    log_dim "docs/TROUBLESHOOTING.md, \"Ansible SSH failure\""
}

main() {
    resolve_target

    if [[ ! -r "$SSH_KEY" ]]; then
        log_err "the private key $SSH_KEY is not readable"
        log_dim "generate one with ./bootstrap/create-secrets.sh, or pass --key"
        exit 2
    fi

    say log "waiting for SSH: ${SSH_USER}@${ADDRESS} (timeout ${TIMEOUT}s, key ${SSH_KEY})"

    local elapsed=0 result
    while (( elapsed < TIMEOUT )); do
        if result=$(attempt); then
            local observed_hostname observed_user
            observed_hostname=$(printf '%s' "$result" | sed -n 1p)
            observed_user=$(printf '%s' "$result" | sed -n 2p)

            if [[ -n "$EXPECT_HOSTNAME" && "$observed_hostname" != "$EXPECT_HOSTNAME" ]]; then
                log_err "connected to ${ADDRESS} but it calls itself '${observed_hostname}', expected '${EXPECT_HOSTNAME}'"
                log_dim "the DHCP reservation may point at the wrong VM, or a previous host still holds this address"
                exit 1
            fi

            say log_ok "SSH ready after ${elapsed}s: ${observed_user}@${observed_hostname} (${ADDRESS})"
            [[ "$QUIET" == true ]] && printf '%s\n' "$observed_hostname"
            exit 0
        fi

        say printf '%s  %3ds  waiting... (%s)%s\n' "$C_DIM" "$elapsed" \
            "$(printf '%s' "${LAST_ERROR:-no response}" | head -1 | cut -c1-60)" "$C_RESET" >&2
        sleep "$INTERVAL"
        elapsed=$((elapsed + INTERVAL))
    done

    diagnose
    exit 1
}

main "$@"
