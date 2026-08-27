#!/usr/bin/env bash
# =====================================================================
# FORGE-AI :: run drift detection and summarise the result
# =====================================================================
#   ./scripts/drift-check.sh
#   ./scripts/drift-check.sh --fail-on-drift      for a scheduled check
#   ./scripts/drift-check.sh --show               re-read the last report
#
# A thin wrapper over detect-drift.yml that makes the outcome legible
# from a terminal and returns a useful exit code.
#
# Exit codes: 0 in sync, 1 drift found (with --fail-on-drift), 2 error
# =====================================================================
set -Eeuo pipefail

export FORGE_SCRIPT_NAME="drift-check.sh"
# shellcheck source=bootstrap/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../bootstrap" && pwd)/lib/common.sh"
forge_enable_traps

FAIL_ON_DRIFT=false
SHOW_ONLY=false
LIMIT=""

usage() {
    cat <<'USAGE'
Usage: ./scripts/drift-check.sh [OPTIONS]

Runs drift detection and summarises what differs from the desired state.

Options:
  --fail-on-drift   exit 1 when drift is found (for a scheduled check)
  --show            print the most recent report without re-running
  --limit PATTERN   restrict to matching hosts
  -h, --help        this message

Detection changes nothing. Reconciliation is a separate, deliberate
step: ./scripts/../ansible/playbooks/reconcile.yml, or `make reconcile`.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fail-on-drift) FAIL_ON_DRIFT=true; shift ;;
        --show)          SHOW_ONLY=true; shift ;;
        --limit)         LIMIT="${2:?}"; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        *)               log_err "unknown option: $1"; usage; exit 2 ;;
    esac
done

summarise() {
    local report=$1
    [[ -r "$report" ]] || { log_err "no drift report at $report"; return 1; }

    local drifted host_count drifted_count
    drifted=$(jq -r '.drifted' "$report")
    host_count=$(jq -r '.hosts | length' "$report")
    drifted_count=$(jq -r '[.hosts[] | select(.drifted)] | length' "$report")

    printf '\n' >&2
    printf '%s================================================================%s\n' "$C_BOLD" "$C_RESET" >&2
    if [[ "$drifted" == "true" ]]; then
        printf '%s DRIFT DETECTED%s -- %s of %s host(s)\n' "$C_YELLOW" "$C_RESET" "$drifted_count" "$host_count" >&2
    else
        printf '%s IN SYNC%s -- %s host(s) match the desired state\n' "$C_GREEN" "$C_RESET" "$host_count" >&2
    fi
    printf '%s================================================================%s\n' "$C_BOLD" "$C_RESET" >&2
    printf '\n' >&2

    # The jq program is kept free of literal single quotes: it is
    # itself inside a single-quoted shell string, and a stray quote
    # would silently end it. Values are rendered with jq's @json so
    # they are unambiguously delimited without needing any.
    jq -r '
        .hosts[] |
        "  \(.name) (\(.os_family)): \(if .drifted then "DRIFTED" else "in sync" end)\n" +
        "    check-mode changes : \(.changed | length)\n" +
        "    probe failures     : \(.probe_failures | length)" +
        (if (.probe_failures | length) > 0 then
            "\n" + ([.probe_failures[] |
                "      - \(.name): expected \(.expected | @json), observed \(.observed | @json)"]
              | join("\n"))
         else "" end) +
        (if (.changed | length) > 0 then
            "\n" + ([.changed[] | "      - would change: \(.task)"] | join("\n"))
         else "" end)
    ' "$report" >&2

    printf '\n' >&2
    log_dim "detection source: $(jq -r '.mode' "$report")"
    jq -r '.hosts[] | select((.check_mode_unsupported | length) > 0) |
           "  blind spots on \(.name): \(.check_mode_unsupported | join(", "))"' "$report" >&2

    printf '\n' >&2
    log_dim "Markdown report: ${report%.json}.md"

    if [[ "$drifted" == "true" ]]; then
        printf '\n' >&2
        log_warn "Reconciliation is not automatic."
        log_dim "If a deviation is legitimate, change the desired state in Git and open a"
        log_dim "pull request -- do not reconcile it away."
        log_dim "If it is unwanted:  make reconcile"
        return 1
    fi
    return 0
}

main() {
    forge_require_valid_config
    require_commands jq

    local report_dir; report_dir="$(forge_config '.storage.report_dir')/drift"
    local latest="$report_dir/latest.json"

    if [[ "$SHOW_ONLY" == true ]]; then
        summarise "$latest" || { [[ "$FAIL_ON_DRIFT" == true ]] && exit 1; }
        exit 0
    fi

    require_commands ansible-playbook
    log_step "Detecting drift"
    log_dim "this runs the baseline in check mode plus the read-only compliance probes"
    log_dim "nothing is changed"

    local -a command=(ansible-playbook playbooks/detect-drift.yml)
    [[ -f "$FORGE_ROOT/.vault-password" ]] && command+=(--vault-password-file "$FORGE_ROOT/.vault-password")
    [[ -n "$LIMIT" ]] && command+=(--limit "$LIMIT")

    ( cd "$FORGE_ROOT/ansible" && "${command[@]}" ) || {
        log_err "the drift playbook failed"
        log_dim "that is different from finding drift: something stopped the run itself"
        exit 2
    }

    if summarise "$latest"; then
        exit 0
    fi
    [[ "$FAIL_ON_DRIFT" == true ]] && exit 1
    exit 0
}

main "$@"
