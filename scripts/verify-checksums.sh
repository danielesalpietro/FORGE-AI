#!/usr/bin/env bash
# =====================================================================
# FORGE-AI :: verify the integrity of every downloaded artefact
# =====================================================================
#   ./scripts/verify-checksums.sh
#   ./scripts/verify-checksums.sh --record      print YAML to pin
#
# Every artefact this project downloads runs as privileged code on a
# machine it provisions: kernels, initrds, iPXE binaries, wimboot and
# kernel-mode VirtIO drivers. An unverified download is the "tampered
# ISO" threat in docs/SECURITY.md.
#
# Exit codes:
#   0  everything present matches its pin, or is unpinned but reported
#   1  at least one artefact does not match its pin
#   2  usage error
# =====================================================================
set -Eeuo pipefail

export FORGE_SCRIPT_NAME="verify-checksums.sh"
# shellcheck source=bootstrap/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../bootstrap" && pwd)/lib/common.sh"
forge_enable_traps

RECORD=false
STRICT=false

usage() {
    cat <<'USAGE'
Usage: ./scripts/verify-checksums.sh [OPTIONS]

Checks every downloaded artefact against the checksum pinned in
config/poc.yml, and reports the observed digest for anything unpinned.

Options:
  --record    print the YAML needed to pin every unpinned artefact
  --strict    treat an unpinned artefact as a failure
  -h, --help  this message
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --record)   RECORD=true; shift ;;
        --strict)   STRICT=true; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          log_err "unknown option: $1"; usage; exit 2 ;;
    esac
done

FAILURES=0
UNPINNED=0
declare -a RECORD_LINES=()

verify() {
    local label=$1 path=$2 expected=$3 pin_path=$4

    if [[ ! -f "$path" ]]; then
        log_dim "$(printf '%-28s' "$label") not present -- nothing to verify"
        return 0
    fi

    local observed size
    observed=$(sha256sum "$path" | cut -d' ' -f1)
    size=$(du -h "$path" | cut -f1)

    if [[ -z "$expected" ]]; then
        UNPINNED=$((UNPINNED + 1))
        log_warn "$(printf '%-28s' "$label") UNPINNED  ${size}"
        log_dim "  $observed"
        RECORD_LINES+=("$pin_path: \"$observed\"")
        [[ "$STRICT" == true ]] && FAILURES=$((FAILURES + 1))
        return 0
    fi

    if [[ "$observed" == "$expected" ]]; then
        log_ok "$(printf '%-28s' "$label") verified  ${size}"
        return 0
    fi

    FAILURES=$((FAILURES + 1))
    log_err "$(printf '%-28s' "$label") MISMATCH"
    log_dim "  expected $expected"
    log_dim "  observed $observed"
    log_dim "  either the file was replaced, or the pin in config/poc.yml is stale."
    log_dim "  Do not proceed until you know which -- docs/SECURITY.md, \"tampered ISO\"."
}

main() {
    forge_require_valid_config
    log_step "Verifying downloaded artefacts"

    local http_root tftp_root
    http_root=$(forge_config '.storage.http_root')
    tftp_root=$(forge_config '.storage.tftp_root')

    # --- operating system media ---------------------------------------
    verify "Ubuntu Server ISO" \
        "$(forge_config '.media.ubuntu.iso_path')" \
        "$(forge_config '.media.ubuntu.iso_sha256')" \
        "media.ubuntu.iso_sha256"

    verify "Windows Server ISO" \
        "$(forge_config '.media.windows.iso_path')" \
        "$(forge_config '.media.windows.iso_sha256')" \
        "media.windows.iso_sha256"

    verify "VirtIO driver ISO" \
        "$(forge_config '.media.windows.virtio.iso_path')" \
        "$(forge_config '.media.windows.virtio.iso_sha256')" \
        "media.windows.virtio.iso_sha256"

    # --- boot chain ----------------------------------------------------
    # These are unpinned by design: they come from the distribution's
    # own signed packages, so apt already verified them. The digests are
    # recorded so a later change is visible.
    log_step "Boot chain (from distribution packages, recorded not pinned)"
    local artefact
    for artefact in "$tftp_root/undionly.kpxe" "$tftp_root/ipxe.efi" "$http_root/wimboot/wimboot"; do
        if [[ -f "$artefact" ]]; then
            log_ok "$(printf '%-28s' "$(basename "$artefact")") $(sha256sum "$artefact" | cut -d' ' -f1)"
        else
            log_dim "$(printf '%-28s' "$(basename "$artefact")") not present"
        fi
    done

    # --- extracted media ------------------------------------------------
    log_step "Extracted media"
    for artefact in \
        "$http_root/ubuntu/casper/vmlinuz" \
        "$http_root/ubuntu/casper/initrd" \
        "$http_root/windows/media/sources/boot.wim" \
        "$http_root/windows/boot-forge.wim"
    do
        if [[ -f "$artefact" ]]; then
            log_ok "$(printf '%-28s' "$(basename "$artefact")") $(du -h "$artefact" | cut -f1)  $(sha256sum "$artefact" | cut -d' ' -f1 | cut -c1-16)..."
        else
            log_dim "$(printf '%-28s' "$(basename "$artefact")") not present"
        fi
    done

    # --- summary --------------------------------------------------------
    printf '\n' >&2
    if [[ $FAILURES -gt 0 ]]; then
        log_err "$FAILURES artefact(s) do not match their pinned checksum"
    elif [[ $UNPINNED -gt 0 ]]; then
        log_warn "$UNPINNED artefact(s) are present but unpinned"
    else
        log_ok "every present artefact matches its pin"
    fi

    if [[ "$RECORD" == true && ${#RECORD_LINES[@]} -gt 0 ]]; then
        printf '\n' >&2
        log_step "Pin these in config/poc.yml"
        printf '\n' >&2
        local line
        for line in "${RECORD_LINES[@]}"; do
            printf '  %s\n' "$line"
        done
        printf '\n' >&2
        log_dim "Nest them under the matching keys; the dotted form above is the path."
    elif [[ $UNPINNED -gt 0 ]]; then
        log_dim "run with --record to print the YAML needed to pin them"
    fi

    [[ $FAILURES -eq 0 ]]
}

main "$@"
