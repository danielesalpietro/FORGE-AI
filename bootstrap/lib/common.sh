#!/usr/bin/env bash
# =====================================================================
# FORGE-AI :: shared shell helpers
# =====================================================================
# Sourced by every script in bootstrap/ and scripts/. Not executable on
# its own.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# Provides: logging, a useful error trap, confirmation prompts,
# repository-root discovery and configuration reading.
# =====================================================================

# Guard against double-sourcing.
[[ -n "${FORGE_COMMON_SOURCED:-}" ]] && return 0
readonly FORGE_COMMON_SOURCED=1

# ---------------------------------------------------------------------
# Colours -- only when stdout is a terminal, so logs stay readable.
# ---------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
    readonly C_RESET=$'\033[0m'
    readonly C_RED=$'\033[31m'
    readonly C_GREEN=$'\033[32m'
    readonly C_YELLOW=$'\033[33m'
    readonly C_BLUE=$'\033[34m'
    readonly C_DIM=$'\033[2m'
    readonly C_BOLD=$'\033[1m'
else
    readonly C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_DIM='' C_BOLD=''
fi

# ---------------------------------------------------------------------
# Logging. Everything goes to stderr so a script's stdout stays usable
# as data in a pipeline.
# ---------------------------------------------------------------------
log()      { printf '%s[ .. ]%s %s\n'  "$C_BLUE"   "$C_RESET" "$*" >&2; }
log_ok()   { printf '%s[ ok ]%s %s\n'  "$C_GREEN"  "$C_RESET" "$*" >&2; }
log_warn() { printf '%s[warn]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_err()  { printf '%s[FAIL]%s %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; }
log_step() { printf '\n%s==> %s%s\n'   "$C_BOLD"   "$*" "$C_RESET" >&2; }
log_dim()  { printf '%s       %s%s\n'  "$C_DIM"    "$*" "$C_RESET" >&2; }

die() { log_err "$*"; exit 1; }

# ---------------------------------------------------------------------
# Error trap. Reports the command, the line and the call stack, because
# "line 47: command not found" on its own is rarely enough.
# ---------------------------------------------------------------------
forge_error_trap() {
    local exit_code=$?
    local line=$1
    local command=$2

    printf '\n%s================================================================%s\n' "$C_RED" "$C_RESET" >&2
    printf '%s FORGE-AI: %s failed%s\n' "$C_RED" "${FORGE_SCRIPT_NAME:-${0##*/}}" "$C_RESET" >&2
    printf '%s================================================================%s\n' "$C_RED" "$C_RESET" >&2
    printf '  exit code : %s\n' "$exit_code" >&2
    printf '  line      : %s\n' "$line" >&2
    printf '  command   : %s\n' "$command" >&2

    if [[ ${#FUNCNAME[@]} -gt 2 ]]; then
        printf '  call stack:\n' >&2
        local i
        for (( i = 1; i < ${#FUNCNAME[@]} - 1; i++ )); do
            printf '    %s() at %s:%s\n' "${FUNCNAME[$i]}" "${BASH_SOURCE[$i+1]##*/}" "${BASH_LINENO[$i]}" >&2
        done
    fi

    if [[ -n "${FORGE_ERROR_HINT:-}" ]]; then
        printf '\n  %s\n' "$FORGE_ERROR_HINT" >&2
    fi
    printf '\n' >&2
    exit "$exit_code"
}

# Call this at the top of every script, after `set -Eeuo pipefail`.
forge_enable_traps() {
    trap 'forge_error_trap "${LINENO}" "${BASH_COMMAND}"' ERR
    trap 'forge_cleanup' EXIT
}

# Scripts override this to clean up their own temporary state.
forge_cleanup() { :; }

# ---------------------------------------------------------------------
# Repository layout
# ---------------------------------------------------------------------
forge_repo_root() {
    local dir="${BASH_SOURCE[0]%/*}"
    dir="$(cd "$dir" && pwd)"
    # bootstrap/lib -> bootstrap -> repository root
    (cd "$dir/../.." && pwd)
}

FORGE_ROOT="${FORGE_ROOT:-$(forge_repo_root)}"
export FORGE_ROOT

# Prefer the project virtualenv's ansible-playbook over one on PATH, the
# same way the Makefile's ANSIBLE_PLAYBOOK does. prepare-host.sh creates
# that virtualenv precisely so nothing has to touch the system Python,
# but a script invoked directly -- not through `make` -- has no other
# way to find it: bash does not inherit venv activation across scripts,
# and expecting the operator to `source .venv/bin/activate` before every
# ./bootstrap/*.sh or ./scripts/*.sh call is exactly the kind of manual
# step this project tries to design out. Without this, bootstrap.sh,
# destroy.sh, drift-check.sh and smoke-test.sh all failed identically on
# a freshly bootstrapped host with an unactivated venv:
# "ansible-playbook: command not found".
if [[ -x "$FORGE_ROOT/.venv/bin/ansible-playbook" ]]; then
    FORGE_ANSIBLE_PLAYBOOK="$FORGE_ROOT/.venv/bin/ansible-playbook"
else
    FORGE_ANSIBLE_PLAYBOOK="ansible-playbook"
fi
export FORGE_ANSIBLE_PLAYBOOK

# Same reasoning for the ad-hoc `ansible` binary, which smoke-test.sh
# uses for the in-guest Windows checks. It was resolved from PATH alone,
# so on a host where prepare-host.sh had installed Ansible exactly as
# documented -- into the venv, not onto PATH -- every one of those
# checks skipped itself with "ansible is not available" and the smoke
# test still exited 0. Empty is a valid answer here: callers test
# FORGE_ANSIBLE before using it and report the skip honestly.
if [[ -x "$FORGE_ROOT/.venv/bin/ansible" ]]; then
    FORGE_ANSIBLE="$FORGE_ROOT/.venv/bin/ansible"
elif command -v ansible >/dev/null 2>&1; then
    FORGE_ANSIBLE="ansible"
else
    FORGE_ANSIBLE=""
fi
export FORGE_ANSIBLE

# ---------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------
require_command() {
    local command_name=$1
    local hint=${2:-}
    if ! command -v "$command_name" >/dev/null 2>&1; then
        log_err "required command not found: $command_name"
        [[ -n "$hint" ]] && log_dim "$hint"
        return 1
    fi
    return 0
}

require_commands() {
    local missing=0 command_name
    for command_name in "$@"; do
        require_command "$command_name" || missing=1
    done
    [[ $missing -eq 0 ]] || die "install the missing commands and re-run (./bootstrap/prepare-host.sh does this)"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "this script must run as root (try: sudo $0 $*)"
    fi
}

require_not_root() {
    if [[ $EUID -eq 0 ]]; then
        die "do not run this script as root -- it escalates with sudo only where it must"
    fi
}

have_sudo() {
    if [[ $EUID -eq 0 ]]; then return 0; fi
    sudo -n true 2>/dev/null && return 0
    log "sudo access is required; you may be prompted for a password"
    sudo -v 2>/dev/null
}

# ---------------------------------------------------------------------
# Confirmation. Never assume yes from a non-interactive shell.
# ---------------------------------------------------------------------
confirm() {
    local prompt=$1
    local expected=${2:-}

    if [[ "${FORGE_ASSUME_YES:-}" == "1" ]]; then
        log_warn "FORGE_ASSUME_YES=1: proceeding without confirmation -- $prompt"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        log_err "confirmation needed but stdin is not a terminal: $prompt"
        log_dim "set FORGE_ASSUME_YES=1 to proceed non-interactively (be sure)"
        return 1
    fi

    if [[ -n "$expected" ]]; then
        printf '%s\n' "$prompt" >&2
        printf 'Type %s%s%s to proceed: ' "$C_BOLD" "$expected" "$C_RESET" >&2
        local answer; read -r answer
        [[ "$answer" == "$expected" ]] && return 0
        log "not confirmed (expected '$expected', got '${answer:-<empty>}')"
        return 1
    fi

    printf '%s [y/N]: ' "$prompt" >&2
    local answer; read -r answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------
# Configuration access. Delegates to the same Python loader the rest of
# the project uses, so shell and Ansible can never disagree about what
# the configuration says.
# ---------------------------------------------------------------------
forge_config_json() {
    local cache="${FORGE_CONFIG_CACHE:-}"
    if [[ -n "$cache" && -r "$cache" ]]; then
        cat "$cache"
        return 0
    fi
    # The Makefile honours FORGE_CONFIG, so a script reading the
    # configuration behind it must honour the same variable or it will
    # silently report on config/poc.yml while the operator believes they
    # selected another overlay. `or empty` because make exports the
    # variable even when it is unset, so it arrives as "".
    if [[ -n "${FORGE_CONFIG:-}" ]]; then
        "$FORGE_ROOT/scripts/validate-config.py" --json --quiet --config "$FORGE_CONFIG" 2>/dev/null
    else
        "$FORGE_ROOT/scripts/validate-config.py" --json --quiet 2>/dev/null
    fi
}

# forge_config '.provisioning_network.gateway'
forge_config() {
    local query=$1
    local value
    value="$(forge_config_json | jq -r "$query" 2>/dev/null)" || {
        die "could not read '$query' from the configuration; run 'make validate' to see why"
    }
    [[ "$value" == "null" ]] && value=""
    printf '%s' "$value"
}

forge_require_valid_config() {
    if ! "$FORGE_ROOT/scripts/validate-config.py" --quiet >/dev/null 2>&1; then
        log_err "the configuration is not valid"
        "$FORGE_ROOT/scripts/validate-config.py" >&2 || true
        die "fix config/poc.yml and re-run"
    fi
}

# ---------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------
# Random secret suitable for a password or token.
#
# Restricted to [A-Za-z0-9] so the value survives .env parsing, YAML
# quoting and a shell command line without any escaping surprises.
# 32 characters of that alphabet is ~190 bits.
#
# Note the absence of the obvious `tr -dc ... </dev/urandom | head -c N`:
# `head` closes the pipe once it has N bytes, `tr` gets SIGPIPE, and
# under `set -o pipefail` the whole pipeline fails with 141. Reading a
# bounded amount and slicing in bash avoids the pipe entirely.
forge_random_secret() {
    local wanted=${1:-32}
    local pool=""

    # Roughly 24% of random bytes survive the [A-Za-z0-9] filter, so
    # each round over-samples by 8x and the loop tops up in the rare
    # case that is not enough.
    while (( ${#pool} < wanted )); do
        pool+=$(LC_ALL=C tr -dc 'A-Za-z0-9' < <(head -c "$(( wanted * 8 ))" /dev/urandom))
    done

    printf '%s' "${pool:0:wanted}"
}

# Write a file that contains a secret, with the mode set BEFORE the
# content is written -- otherwise there is a window where it is
# world-readable.
forge_write_secret_file() {
    local path=$1
    local content=$2
    local mode=${3:-0600}

    mkdir -p "$(dirname "$path")"
    install -m "$mode" /dev/null "$path"
    printf '%s' "$content" > "$path"
    chmod "$mode" "$path"
}

forge_timestamp() { date -u +%Y%m%dT%H%M%SZ; }

forge_banner() {
    printf '%s' "$C_BOLD" >&2
    cat >&2 <<'BANNER'
  ______ ____  _____   _____ ______        _____
 |  ____/ __ \|  __ \ / ____|  ____|      /  _  \_ _
 | |__ | |  | | |__) | |  __| |__   ___  |  /_\  | |
 |  __|| |  | |  _  /| | |_ |  __| |___| |  _  | | |
 | |   | |__| | | \ \| |__| | |____      | | | | | |
 |_|    \____/|_|  \_\\_____|______|     |_| |_|_|_|

 GitOps infrastructure provisioning -- Proof of Concept
BANNER
    printf '%s\n' "$C_RESET" >&2
}
