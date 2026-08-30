#!/usr/bin/env bash
# =====================================================================
# FORGE-AI :: download, verify and unpack the Ubuntu Server ISO
# =====================================================================
#   ./scripts/prepare-ubuntu-iso.sh
#   ./scripts/prepare-ubuntu-iso.sh --force
#
# A thin, dependency-free equivalent of the ubuntu_media Ansible role,
# for operators who want the media in place before the control plane is
# up -- or who are debugging why the role failed.
#
# Ubuntu 24.04 ships no netboot.tar.gz for Server, so the supported
# network path is: boot casper/vmlinuz + casper/initrd extracted from
# the ISO, and let casper fetch the ISO itself over HTTP.
# =====================================================================
set -Eeuo pipefail

export FORGE_SCRIPT_NAME="prepare-ubuntu-iso.sh"
# shellcheck source=bootstrap/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../bootstrap" && pwd)/lib/common.sh"
forge_enable_traps

FORCE=false
SKIP_VERIFY=false

usage() {
    cat <<'USAGE'
Usage: ./scripts/prepare-ubuntu-iso.sh [OPTIONS]

Downloads the Ubuntu Server ISO named in config/poc.yml, verifies its
SHA-256, and extracts the kernel and initrd the PXE boot needs.

Options:
  --force        re-download even if the ISO is present and matches
  --skip-verify  accept an unverified ISO (deliberately loud)
  -h, --help     this message

Checksum policy:
  media.ubuntu.iso_sha256 pinned  -> authoritative, works air-gapped
  media.ubuntu.iso_sha256 empty   -> fetched from the official SHA256SUMS
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)       FORCE=true; shift ;;
        --skip-verify) SKIP_VERIFY=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             log_err "unknown option: $1"; usage; exit 2 ;;
    esac
done

main() {
    forge_require_valid_config
    require_commands curl sha256sum 7z

    local iso_url iso_path iso_sha256 http_root version
    iso_url=$(forge_config '.media.ubuntu.iso_url')
    iso_path=$(forge_config '.media.ubuntu.iso_path')
    iso_sha256=$(forge_config '.media.ubuntu.iso_sha256')
    http_root=$(forge_config '.storage.http_root')
    version=$(forge_config '.media.ubuntu.version')

    log_step "Ubuntu Server ${version}"
    log_dim "source : $iso_url"
    log_dim "target : $iso_path"

    # --- establish the expected checksum ------------------------------
    local expected="$iso_sha256"
    if [[ "$SKIP_VERIFY" == true ]]; then
        log_warn "--skip-verify: the ISO will NOT be verified"
        log_dim "installing from unverified media is the 'tampered ISO' threat in docs/SECURITY.md"
        expected=""
    elif [[ -z "$expected" ]]; then
        local series sums_url
        series=$(printf '%s' "$version" | cut -d. -f1,2)
        sums_url="https://releases.ubuntu.com/${series}/SHA256SUMS"
        log "no checksum pinned; fetching $sums_url"
        expected=$(curl -fsS --max-time 60 "$sums_url" \
                   | grep -F "$(basename "$iso_url")" \
                   | head -1 | cut -d' ' -f1 || true)
        if [[ ${#expected} -ne 64 ]]; then
            log_err "could not determine the expected SHA-256"
            log_dim "pin it in config/poc.yml under media.ubuntu.iso_sha256,"
            log_dim "or make $sums_url reachable from this host"
            exit 1
        fi
        log_ok "expected SHA-256: $expected"
    else
        log_ok "using the pinned SHA-256: $expected"
    fi

    # --- download ------------------------------------------------------
    mkdir -p "$(dirname "$iso_path")" "$http_root/ubuntu/casper" "$http_root/iso"

    local need_download=true
    if [[ -f "$iso_path" && "$FORCE" == false ]]; then
        if [[ -z "$expected" ]]; then
            log_ok "ISO already present (unverified)"
            need_download=false
        else
            log "verifying the existing ISO"
            local observed; observed=$(sha256sum "$iso_path" | cut -d' ' -f1)
            if [[ "$observed" == "$expected" ]]; then
                log_ok "existing ISO matches"
                need_download=false
            else
                log_warn "the existing ISO does not match; re-downloading"
            fi
        fi
    fi

    if [[ "$need_download" == true ]]; then
        log "downloading $(basename "$iso_url") -- this is around 3 GB"
        # --continue-at - resumes a partial download rather than
        # starting a multi-gigabyte transfer again.
        curl -fL --progress-bar --continue-at - -o "$iso_path" "$iso_url"

        if [[ -n "$expected" ]]; then
            log "verifying"
            local observed; observed=$(sha256sum "$iso_path" | cut -d' ' -f1)
            if [[ "$observed" != "$expected" ]]; then
                log_err "checksum mismatch after download"
                log_dim "  expected $expected"
                log_dim "  observed $observed"
                log_dim "the file is left in place for inspection; delete it and retry"
                exit 1
            fi
            log_ok "verified"
        fi
    fi

    # --- extract --------------------------------------------------------
    log_step "Extracting the boot files"
    if [[ -f "$http_root/ubuntu/casper/initrd" && "$FORCE" == false ]]; then
        log_ok "kernel and initrd already extracted"
    else
        # 7z reads ISO 9660 directly: no loop mount, so this needs no
        # root and leaves nothing behind if interrupted.
        7z x -y "-o${http_root}/ubuntu" "$iso_path" "casper/vmlinuz" "casper/initrd" >/dev/null
        log_ok "extracted casper/vmlinuz and casper/initrd"
    fi

    local artefact
    for artefact in vmlinuz initrd; do
        local path="$http_root/ubuntu/casper/$artefact"
        if [[ ! -f "$path" ]]; then
            log_err "$artefact is missing after extraction"
            log_dim "is $iso_path a live-server ISO? The desktop image has a different layout."
            exit 1
        fi
        local size; size=$(stat -c '%s' "$path")
        if (( size < 1000000 )); then
            log_err "$artefact is implausibly small (${size} bytes) -- the ISO may be truncated"
            exit 1
        fi
        chmod 0644 "$path"
        log_ok "$(printf '%-10s' "$artefact") $(du -h "$path" | cut -f1)"
    done

    # --- publish over HTTP ----------------------------------------------
    log_step "Publishing the ISO for casper"
    local published
    published="$http_root/iso/$(basename "$iso_path")"
    if [[ -e "$published" ]] && [[ "$(stat -c '%i' "$published")" == "$(stat -c '%i' "$iso_path")" ]]; then
        log_ok "already published (hard link)"
    else
        rm -f "$published"
        # A hard link avoids a second 3 GB copy. It only works within one
        # filesystem, so fall back to a copy.
        if ln "$iso_path" "$published" 2>/dev/null; then
            log_ok "hard-linked into $http_root/iso/"
        else
            log_warn "iso_dir and http_root are on different filesystems; copying instead"
            cp "$iso_path" "$published"
            log_ok "copied into $http_root/iso/"
        fi
    fi
    chmod 0644 "$published"

    log_step "Done"
    cat >&2 <<SUMMARY

  ISO      $iso_path
  SHA-256  ${expected:-not verified}
  kernel   $http_root/ubuntu/casper/vmlinuz
  initrd   $http_root/ubuntu/casper/initrd
  served   $published

  Next: make deploy-pxe    (renders the autoinstall seed and boot scripts)

SUMMARY
}

main "$@"
