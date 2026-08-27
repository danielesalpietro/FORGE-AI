#!/usr/bin/env bash
# =====================================================================
# FORGE-AI :: validate and unpack the operator-supplied Windows media
# =====================================================================
#   ./scripts/prepare-windows-iso.sh
#   ./scripts/prepare-windows-iso.sh --list-images     just show editions
#   ./scripts/prepare-windows-iso.sh --iso /path/to.iso
#
# NOTHING FROM MICROSOFT IS REDISTRIBUTED BY THIS REPOSITORY. The
# operator supplies the ISO; this script validates it, records its
# checksum, lists the editions inside install.wim and extracts the
# contents for the SMB export WinPE reads.
#
# Obtaining Windows Server 2025 Evaluation media legally is documented
# in docs/WINDOWS-PROVISIONING.md.
# =====================================================================
set -Eeuo pipefail

export FORGE_SCRIPT_NAME="prepare-windows-iso.sh"
# shellcheck source=bootstrap/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../bootstrap" && pwd)/lib/common.sh"
forge_enable_traps

FORCE=false
LIST_ONLY=false
ISO_OVERRIDE=""

usage() {
    cat <<'USAGE'
Usage: ./scripts/prepare-windows-iso.sh [OPTIONS]

Validates the operator-supplied Windows Server ISO and unpacks it.

Options:
  --iso PATH      use this ISO instead of media.windows.iso_path
  --list-images   list the editions inside install.wim and exit
  --force         re-extract even if the media directory is populated
  -h, --help      this message

The edition listing matters: index 1 on a Windows Server ISO is normally
Standard *Core*, not the Desktop Experience image most people expect,
and the mistake only becomes visible after a 20-minute installation.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso)         ISO_OVERRIDE="${2:?}"; shift 2 ;;
        --list-images) LIST_ONLY=true; shift ;;
        --force)       FORCE=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             log_err "unknown option: $1"; usage; exit 2 ;;
    esac
done

no_media_guidance() {
    cat >&2 <<'GUIDANCE'

  No Windows Server ISO is configured.

  This repository does not, and will not, redistribute Microsoft media.
  You supply it:

    1. Download Windows Server 2025 Evaluation from the Microsoft
       Evaluation Center. It is a free 180-day evaluation; using it is
       subject to Microsoft's licensing terms, which are yours to accept.

    2. Put the ISO somewhere this host can read, for example
       /srv/forge-ai/iso/windows-server-2025-eval.iso

    3. Point config/poc.yml at it:

         media:
           windows:
             iso_path: /srv/forge-ai/iso/windows-server-2025-eval.iso

    4. List the editions it contains and copy the exact name:

         ./scripts/prepare-windows-iso.sh --list-images

  The Ubuntu target does not depend on any of this. Deploy it alone with:

    make provision-ubuntu

  Full procedure and licensing notes: docs/WINDOWS-PROVISIONING.md

GUIDANCE
}

list_editions() {
    local image=$1
    log_step "Editions inside $(basename "$image")"
    printf '\n' >&2

    # wimlib-imagex reads WIM and ESD metadata on Linux; no DISM and no
    # Windows machine are needed.
    wimlib-imagex info "$image" 2>/dev/null | awk '
        /^Index:/            { index_number = $2 }
        /^Name:/             { $1 = ""; name = substr($0, 2) }
        /^Description:/      { $1 = ""; description = substr($0, 2) }
        /^Total Bytes:/      { bytes = $3;
                               printf "  [%s] %-46s %6.1f GB\n", index_number, name, bytes/1073741824;
                               if (description != name && description != "") printf "        %s\n", description;
                               name = ""; description = "" }
    ' >&2

    printf '\n' >&2
    log_dim "Copy one of these names verbatim into config/poc.yml:"
    log_dim ""
    log_dim "  media:"
    log_dim "    windows:"
    log_dim "      image_name: \"Windows Server 2025 SERVERSTANDARD\""
    log_dim ""
    log_dim "Names are case-sensitive in practice and differ between ISOs."
    log_dim "Index 1 is normally Standard Core: no desktop, no GUI tools."
}

main() {
    forge_require_valid_config
    require_commands sha256sum 7z wimlib-imagex

    local iso_path
    iso_path="${ISO_OVERRIDE:-$(forge_config '.media.windows.iso_path')}"

    if [[ -z "$iso_path" ]]; then
        log_err "media.windows.iso_path is empty"
        no_media_guidance
        exit 1
    fi

    if [[ ! -f "$iso_path" ]]; then
        log_err "the configured Windows ISO does not exist: $iso_path"
        no_media_guidance
        exit 1
    fi

    if [[ ! -r "$iso_path" ]]; then
        log_err "the Windows ISO is not readable by $(id -un): $iso_path"
        log_dim "  ls -l '$iso_path'"
        exit 1
    fi

    log_step "Windows Server media"
    log_ok "$(printf '%-10s' "ISO") $iso_path ($(du -h "$iso_path" | cut -f1))"

    # --- checksum -------------------------------------------------------
    log "computing the SHA-256 (this reads the whole file)"
    local observed pinned
    observed=$(sha256sum "$iso_path" | cut -d' ' -f1)
    pinned=$(forge_config '.media.windows.iso_sha256')

    if [[ ${#pinned} -eq 64 ]]; then
        if [[ "$observed" == "$pinned" ]]; then
            log_ok "matches the pinned checksum"
        else
            log_err "checksum mismatch"
            log_dim "  expected $pinned"
            log_dim "  observed $observed"
            log_dim "either the ISO was replaced or the pin is stale."
            log_dim "Do not proceed until you know which -- docs/SECURITY.md, 'tampered ISO'."
            exit 1
        fi
    else
        log_warn "no checksum pinned"
        log_dim "SHA-256: $observed"
        log_dim "pin it in config/poc.yml so a substituted ISO is detected:"
        log_dim ""
        log_dim "  media:"
        log_dim "    windows:"
        log_dim "      iso_sha256: \"$observed\""
    fi

    local http_root
    http_root=$(forge_config '.storage.http_root')
    local media_dir="$http_root/windows/media"

    # --- extract ---------------------------------------------------------
    if [[ "$LIST_ONLY" == true ]]; then
        # Pull just install.wim out to a temporary location rather than
        # unpacking 5 GB the operator did not ask for.
        if [[ -f "$media_dir/sources/install.wim" ]]; then
            list_editions "$media_dir/sources/install.wim"
        elif [[ -f "$media_dir/sources/install.esd" ]]; then
            list_editions "$media_dir/sources/install.esd"
        else
            local temporary; temporary=$(mktemp -d)
            # shellcheck disable=SC2064
            trap "rm -rf '$temporary'" EXIT
            log "extracting sources/install.wim to inspect it"
            7z x -y "-o${temporary}" "$iso_path" "sources/install.wim" "sources/install.esd" >/dev/null 2>&1 || true
            local image
            image=$(find "$temporary" -iname 'install.*' -type f | head -1)
            [[ -n "$image" ]] || die "no sources/install.wim or install.esd inside $iso_path -- is this a Windows installation ISO?"
            list_editions "$image"
        fi
        exit 0
    fi

    log_step "Extracting the installation media"
    mkdir -p "$media_dir"

    if [[ -f "$media_dir/sources/install.wim" || -f "$media_dir/sources/install.esd" ]] && [[ "$FORCE" == false ]]; then
        log_ok "already extracted (pass --force to redo)"
    else
        log "extracting -- this takes a few minutes and needs around 10 GB"
        7z x -y "-o${media_dir}" "$iso_path" >/dev/null
        log_ok "extracted to $media_dir"
    fi

    # --- validate what came out ------------------------------------------
    local install_image=""
    for candidate in install.wim install.esd; do
        if [[ -f "$media_dir/sources/$candidate" ]]; then
            install_image="$media_dir/sources/$candidate"
            break
        fi
    done

    [[ -n "$install_image" ]] || die "no sources/install.wim or install.esd after extraction -- is this a Windows installation ISO?"
    [[ -f "$media_dir/sources/boot.wim" ]] || die "no sources/boot.wim after extraction -- WinPE cannot be built without it"

    log_ok "$(printf '%-14s' "install image") $(basename "$install_image") ($(du -h "$install_image" | cut -f1))"
    log_ok "$(printf '%-14s' "WinPE image") boot.wim ($(du -h "$media_dir/sources/boot.wim" | cut -f1))"

    # The ISO's own casing varies between Windows releases.
    local found
    for name in bootmgr.efi bcd boot.sdi; do
        found=$(find "$media_dir" -maxdepth 2 -iname "$name" -type f | head -1)
        if [[ -n "$found" ]]; then
            log_ok "$(printf '%-14s' "$name") $found"
        else
            log_err "$name is missing from the extracted media"
            log_dim "wimboot needs bootmgr.efi, BCD and boot.sdi alongside boot.wim"
            exit 1
        fi
    done

    list_editions "$install_image"

    # --- confirm the configured edition exists ----------------------------
    local configured_name
    configured_name=$(forge_config '.media.windows.image_name')
    if [[ -n "$configured_name" ]]; then
        if wimlib-imagex info "$install_image" 2>/dev/null | grep -qiF "$configured_name"; then
            log_ok "the configured edition is present: \"$configured_name\""
        else
            log_err "the configured edition is NOT in this image: \"$configured_name\""
            log_dim "copy one of the names listed above into media.windows.image_name"
            exit 1
        fi
    fi

    log_step "Done"
    cat >&2 <<SUMMARY

  ISO       $iso_path
  SHA-256   $observed
  media     $media_dir
  edition   ${configured_name:-<not set -- choose one from the list above>}

  Next: make prepare-windows-media
        (injects the VirtIO drivers into WinPE and renders Autounattend.xml)

SUMMARY
}

main "$@"
