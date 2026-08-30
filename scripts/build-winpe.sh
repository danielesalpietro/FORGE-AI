#!/usr/bin/env bash
# =====================================================================
# FORGE-AI :: build the network-bootable WinPE image
# =====================================================================
#   ./scripts/build-winpe.sh
#   ./scripts/build-winpe.sh --force
#   ./scripts/build-winpe.sh --verify-only
#
# Takes boot.wim from the operator-supplied Windows ISO and injects the
# VirtIO drivers WinPE needs, using wimlib-imagex -- on Linux, with no
# Windows machine and no ADK.
#
# WHY THIS IS NEEDED
#   WinPE has no in-box VirtIO driver:
#     no viostor -> diskpart reports "There are no fixed disks to show"
#     no NetKVM  -> wpeinit finds no NIC and the SMB mount times out
#
# WHEN THE ADK IS NEEDED INSTEAD
#   This script cannot add WinPE optional components -- PowerShell,
#   WMI, .NET. Those require the Windows ADK on a Windows workstation.
#   Nothing in this PoC needs them (startnet.cmd is plain batch), but if
#   you customise the WinPE stage you may. The procedure and the
#   media.windows.winpe_source: prebuilt handoff are documented in
#   docs/WINDOWS-PROVISIONING.md.
# =====================================================================
set -Eeuo pipefail

export FORGE_SCRIPT_NAME="build-winpe.sh"
# shellcheck source=bootstrap/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../bootstrap" && pwd)/lib/common.sh"
forge_enable_traps

FORCE=false
VERIFY_ONLY=false
STAGING=""

forge_cleanup() {
    [[ -n "$STAGING" && -d "$STAGING" ]] && rm -rf "$STAGING"
    return 0
}

usage() {
    cat <<'USAGE'
Usage: ./scripts/build-winpe.sh [OPTIONS]

Injects the VirtIO drivers into boot.wim so WinPE can see the disk and
the network. Runs entirely on Linux via wimlib-imagex.

Options:
  --force        rebuild from pristine media even if an image exists
  --verify-only  check an existing image and report, build nothing
  -h, --help     this message

Prerequisites:
  make prepare-windows-media   (extracts boot.wim and the VirtIO drivers)
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)       FORCE=true; shift ;;
        --verify-only) VERIFY_ONLY=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             log_err "unknown option: $1"; usage; exit 2 ;;
    esac
done

find_setup_image_index() {
    # A Windows installation boot.wim holds two images: index 1 is bare
    # "Microsoft Windows PE", index 2 is "Microsoft Windows Setup". Only
    # the Setup image boots into the installer, so it is found by name
    # rather than assumed.
    local image=$1
    wimlib-imagex info "$image" 2>/dev/null \
        | awk '/^Index:/{idx=$2} /^Name:/{ if ($0 ~ /Setup/) { print idx; exit } }'
}

verify_image() {
    local image=$1 index=$2
    local count
    count=$(wimlib-imagex dir "$image" "$index" 2>/dev/null \
            | grep -ci '\\Windows\\System32\\drivers\\forge\\.*\.inf' || true)

    if (( count > 0 )); then
        log_ok "$count driver .inf file(s) present inside image $index"
        wimlib-imagex dir "$image" "$index" 2>/dev/null \
            | grep -i '\\drivers\\forge\\.*\.inf' | sed 's/^/       /' >&2
        return 0
    fi

    log_err "no .inf files under \\Windows\\System32\\drivers\\forge in image $index"
    log_dim "WinPE will boot, but drvload will have nothing to load:"
    log_dim "  no viostor -> diskpart reports \"There are no fixed disks to show\""
    log_dim "  no NetKVM  -> wpeinit finds no NIC and the SMB mount times out"
    return 1
}

main() {
    forge_require_valid_config
    require_commands wimlib-imagex

    local http_root
    http_root=$(forge_config '.storage.http_root')

    local source_wim="$http_root/windows/media/sources/boot.wim"
    local target_wim="$http_root/windows/boot-forge.wim"
    local virtio_dir="$http_root/windows/virtio"

    if [[ "$VERIFY_ONLY" == true ]]; then
        [[ -f "$target_wim" ]] || die "$target_wim does not exist; run without --verify-only to build it"
        local index; index=$(find_setup_image_index "$target_wim")
        log_step "Verifying $target_wim (image ${index:-2})"
        verify_image "$target_wim" "${index:-2}"
        exit $?
    fi

    log_step "Building the FORGE-AI WinPE image"

    if [[ ! -f "$source_wim" ]]; then
        log_err "$source_wim does not exist"
        log_dim "extract the operator-supplied Windows ISO first:"
        log_dim "  make prepare-windows-media"
        log_dim "or: ./scripts/prepare-windows-iso.sh"
        exit 1
    fi
    log_ok "source     $source_wim ($(du -h "$source_wim" | cut -f1))"

    if [[ ! -d "$virtio_dir" ]]; then
        log_err "$virtio_dir does not exist"
        log_dim "the VirtIO drivers are downloaded by the windows_media role:"
        log_dim "  make prepare-windows-media"
        exit 1
    fi

    if [[ -f "$target_wim" && "$FORCE" == false ]]; then
        log_ok "an image already exists; verifying it instead of rebuilding"
        local index; index=$(find_setup_image_index "$target_wim")
        if verify_image "$target_wim" "${index:-2}"; then
            log_dim "pass --force to rebuild from pristine media"
            exit 0
        fi
        log_warn "the existing image is not usable; rebuilding"
    fi

    # Copy so the extracted media stays pristine and a --force rebuild
    # always starts from a known state.
    log "copying boot.wim so the extracted media stays pristine"
    cp -f "$source_wim" "$target_wim"
    chmod 0644 "$target_wim"

    local index; index=$(find_setup_image_index "$target_wim")
    if [[ -z "$index" ]]; then
        log_warn "could not find a 'Setup' image by name; defaulting to index 2"
        log_dim "images in this boot.wim:"
        wimlib-imagex info "$target_wim" | grep -E '^(Index|Name):' | sed 's/^/       /' >&2
        index=2
    fi
    log_ok "target     image $index ($(wimlib-imagex info "$target_wim" "$index" 2>/dev/null | sed -n 's/^Name:[[:space:]]*//p'))"

    # --- stage the drivers ------------------------------------------------
    STAGING=$(mktemp -d)
    local collected=0 path source_path
    while read -r path; do
        [[ -n "$path" ]] || continue
        source_path="$virtio_dir/$path"
        if [[ -d "$source_path" ]]; then
            # Copy the whole per-architecture directory: every .inf needs
            # its .sys and .cat siblings, and enumerating them is fragile.
            cp -a "$source_path"/. "$STAGING"/ 2>/dev/null || true
            collected=$((collected + 1))
            log_ok "staged     $path"
        else
            log_warn "missing    $path"
            log_dim "the per-OS sub-directory names change between virtio-win releases"
            log_dim "list what this ISO has:  ls $virtio_dir/viostor/"
        fi
    done < <(forge_config '.media.windows.virtio.driver_paths[]')

    if [[ $collected -eq 0 ]]; then
        log_err "no VirtIO driver directory was found"
        log_dim "correct media.windows.virtio.driver_paths in config/poc.yml"
        exit 1
    fi

    local inf_count; inf_count=$(find "$STAGING" -iname '*.inf' | wc -l)
    log_ok "collected  $inf_count .inf file(s) from $collected directory/directories"

    # --- inject -----------------------------------------------------------
    log "injecting into \\Windows\\System32\\drivers\\forge"
    wimlib-imagex update "$target_wim" "$index" \
        --command="add '$STAGING' '\\Windows\\System32\\drivers\\forge'" >/dev/null

    verify_image "$target_wim" "$index" || exit 1

    log_step "Done"
    cat >&2 <<SUMMARY

  image      $target_wim ($(du -h "$target_wim" | cut -f1))
  index      $index
  drivers    \\Windows\\System32\\drivers\\forge
  loaded by  startnet.cmd, with drvload, storage first

  The per-host copies are staged by the windows_winpe role. Next:
    make prepare-windows-media
    make provision-windows

SUMMARY
}

main "$@"
