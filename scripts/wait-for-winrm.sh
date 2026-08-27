#!/usr/bin/env bash
# =====================================================================
# FORGE-AI :: wait until a Windows host answers WinRM over HTTPS
# =====================================================================
#   ./scripts/wait-for-winrm.sh 192.168.250.22
#   ./scripts/wait-for-winrm.sh poc-windows-01 --timeout 2400 --validate-tls
#
# Three layers are checked, in order, because "WinRM is not working"
# has three very different causes:
#
#   1. TCP  -- is anything listening on 5986?
#   2. TLS  -- does it complete a handshake, and with what certificate?
#   3. WS-Man -- does it answer a SOAP Identify request?
#
# Layer 3 matters: a TLS handshake succeeds as soon as the listener
# exists, but the WinRM service can still be refusing requests while
# Windows finishes its first boot.
#
# Exit codes:
#   0  WinRM answers a WS-Man Identify request
#   1  timed out
#   2  usage error
# =====================================================================
set -Eeuo pipefail

export FORGE_SCRIPT_NAME="wait-for-winrm.sh"
# shellcheck source=bootstrap/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../bootstrap" && pwd)/lib/common.sh"
forge_enable_traps

TARGET=""
TIMEOUT=1800
INTERVAL=15
PORT=""
VALIDATE_TLS=false
QUIET=false

usage() {
    cat <<'USAGE'
Usage: ./scripts/wait-for-winrm.sh TARGET [OPTIONS]

TARGET is an IP address, or a host name from config/poc.yml.

Options:
  --timeout SECONDS   give up after this long        (default 1800)
  --interval SECONDS  seconds between attempts       (default 15)
  --port PORT         override the WinRM port        (default from config)
  --validate-tls      require a trusted certificate  (see below)
  --quiet             only report the final result
  -h, --help          this message

--validate-tls is OFF by default because the PoC's WinRM certificate is
generated self-signed during the Windows specialize phase. Turning it on
without first enrolling that certificate in this host's trust store will
fail, correctly. docs/SECURITY.md explains how to move to a CA-issued
certificate; the default is a deliberate, documented PoC shortcut and
not a silent one.

Exit codes:
  0  WinRM answered a WS-Man Identify request
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
        --timeout)      TIMEOUT="${2:?}"; shift 2 ;;
        --interval)     INTERVAL="${2:?}"; shift 2 ;;
        --port)         PORT="${2:?}"; shift 2 ;;
        --validate-tls) VALIDATE_TLS=true; shift ;;
        --quiet)        QUIET=true; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              log_err "unknown option: $1"; usage; exit 2 ;;
    esac
done

say() { [[ "$QUIET" == true ]] || "$@"; }

resolve_target() {
    if [[ "$TARGET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        ADDRESS="$TARGET"
        HOST_NAME=$(forge_config ".hosts[] | select(.ip_address == \"$TARGET\") | .name" 2>/dev/null || echo "")
    else
        ADDRESS=$(forge_config ".hosts[] | select(.name == \"$TARGET\") | .ip_address")
        HOST_NAME="$TARGET"
        if [[ -z "$ADDRESS" ]]; then
            log_err "'$TARGET' is neither an IPv4 address nor a host in config/poc.yml"
            log_dim "configured hosts: $(forge_config '[.hosts[].name] | join(", ")')"
            exit 2
        fi
    fi
    [[ -n "$PORT" ]] || PORT=$(forge_config '.security.winrm_port' 2>/dev/null || echo 5986)
    [[ -n "$PORT" ]] || PORT=5986
}

# --- layer 1: TCP -----------------------------------------------------
check_tcp() {
    timeout 5 bash -c "printf '' > /dev/tcp/${ADDRESS}/${PORT}" 2>/dev/null
}

# --- layer 2: TLS -----------------------------------------------------
check_tls() {
    local options=(-connect "${ADDRESS}:${PORT}" -servername "${HOST_NAME:-$ADDRESS}" -brief)
    if [[ "$VALIDATE_TLS" == false ]]; then
        # Explicit and scoped to this probe: it does not change any
        # global TLS behaviour, and the flag it corresponds to is
        # visible in the output below.
        options+=(-verify_return_error 0)
    fi
    TLS_OUTPUT=$(timeout 10 openssl s_client "${options[@]}" </dev/null 2>&1) || return 1

    if [[ "$VALIDATE_TLS" == true ]] && printf '%s' "$TLS_OUTPUT" | grep -qi "verify error"; then
        return 1
    fi
    return 0
}

certificate_details() {
    timeout 10 openssl s_client -connect "${ADDRESS}:${PORT}" </dev/null 2>/dev/null \
        | openssl x509 -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null \
        | sed 's/^/       /'
}

# --- layer 3: WS-Man --------------------------------------------------
# An unauthenticated Identify request. WinRM answers it with a SOAP
# envelope naming the product vendor, which proves the service is up and
# processing requests rather than merely listening.
readonly WSMAN_IDENTIFY='<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:wsmid="http://schemas.dmtf.org/wbem/wsman/identity/1/wsmanidentity.xsd"><s:Header/><s:Body><wsmid:Identify/></s:Body></s:Envelope>'

check_wsman() {
    local -a curl_options=(
        --silent --show-error
        --max-time 15
        -X POST
        -H 'Content-Type: application/soap+xml;charset=UTF-8'
        --data-binary "$WSMAN_IDENTIFY"
    )
    [[ "$VALIDATE_TLS" == false ]] && curl_options+=(--insecure)

    WSMAN_OUTPUT=$(curl "${curl_options[@]}" "https://${ADDRESS}:${PORT}/wsman" 2>&1) || return 1
    printf '%s' "$WSMAN_OUTPUT" | grep -qi "ProductVendor\|ProductVersion\|wsmid:IdentifyResponse"
}

diagnose() {
    printf '\n' >&2
    log_err "timed out after ${TIMEOUT}s waiting for WinRM on ${ADDRESS}:${PORT}"
    printf '\n' >&2

    if ping -c 2 -W 2 "$ADDRESS" >/dev/null 2>&1; then
        log_ok "ICMP: $ADDRESS responds"
    else
        log_err "ICMP: $ADDRESS does not respond"
        log_dim "Windows Setup may still be running -- it takes 15-30 minutes"
        log_dim "  virsh list --all"
        log_dim "  curl -s $(forge_config '.control_plane.address' 2>/dev/null || echo 192.168.250.1):8080/api/state | jq"
        log_dim "  virt-viewer --connect qemu:///system ${HOST_NAME:-<domain>}"
    fi

    if check_tcp; then
        log_ok "TCP: port ${PORT} is open"
        if check_tls; then
            log_ok "TLS: handshake completes"
            log_dim "certificate presented:"
            certificate_details >&2 || true
            log_err "but WS-Man did not answer an Identify request"
            log_dim "last response: $(printf '%s' "${WSMAN_OUTPUT:-none}" | head -c 200)"
            log_dim "the listener exists but the service is refusing requests -- usually because"
            log_dim "Windows is still finishing its first boot. Give it longer with --timeout."
        else
            log_err "TLS: handshake failed"
            log_dim "$(printf '%s' "${TLS_OUTPUT:-no output}" | head -3)"
            [[ "$VALIDATE_TLS" == true ]] && \
                log_dim "--validate-tls is set: the self-signed PoC certificate will fail this. See docs/SECURITY.md."
        fi
    else
        log_err "TCP: port ${PORT} is closed or filtered"
        log_dim "SetupComplete.cmd creates the HTTPS listener. If Windows installed but this"
        log_dim "port never opened, that script did not run or Configure-WinRM.ps1 failed."
        log_dim "Recover from the VM console:"
        log_dim "  powershell -ExecutionPolicy Bypass -File C:\\Windows\\Setup\\Scripts\\Configure-WinRM.ps1"
        log_dim "and read C:\\ProgramData\\forge-ai\\setupcomplete.log"
    fi

    printf '\n' >&2
    log_dim "docs/TROUBLESHOOTING.md, \"WinRM listener unavailable\""
}

main() {
    resolve_target

    say log "waiting for WinRM: https://${ADDRESS}:${PORT}/wsman (timeout ${TIMEOUT}s)"
    if [[ "$VALIDATE_TLS" == false ]]; then
        say log_warn "TLS validation is disabled for this probe (PoC self-signed certificate)"
        say log_dim "pass --validate-tls once a trusted certificate is enrolled"
    fi

    local elapsed=0 stage="waiting for the VM"
    while (( elapsed < TIMEOUT )); do
        if check_tcp; then
            stage="TCP open"
            if check_tls; then
                stage="TLS ok"
                if check_wsman; then
                    local vendor
                    vendor=$(printf '%s' "$WSMAN_OUTPUT" \
                             | grep -o '<wsmid:ProductVersion>[^<]*' | cut -d'>' -f2 || true)
                    say log_ok "WinRM ready after ${elapsed}s -- ${vendor:-WS-Man Identify answered}"
                    say log_dim "certificate:"
                    [[ "$QUIET" == true ]] || certificate_details >&2 || true
                    [[ "$QUIET" == true ]] && printf 'ready\n'
                    exit 0
                fi
                stage="TLS ok, WS-Man not answering yet"
            else
                stage="TCP open, TLS handshake failing"
            fi
        fi

        say printf '%s  %4ds  %s%s\n' "$C_DIM" "$elapsed" "$stage" "$C_RESET" >&2
        sleep "$INTERVAL"
        elapsed=$((elapsed + INTERVAL))
    done

    diagnose
    exit 1
}

main "$@"
