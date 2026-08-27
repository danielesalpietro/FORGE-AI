#!/usr/bin/env bash
# =====================================================================
# FORGE-AI :: stage the iPXE and wimboot boot binaries
# =====================================================================
#   ./scripts/download-ipxe-assets.sh
#   ./scripts/download-ipxe-assets.sh --build --ref v1.21.1
#
# Two sources, in order of preference:
#
#   distro (default)  copy from the Ubuntu `ipxe` and `ipxe-qemu`
#                     packages. apt already verified their signatures,
#                     so nothing unsigned enters the boot chain.
#
#   build             compile from a pinned iPXE git tag. Slower, needs
#                     a toolchain, but produces a binary the operator
#                     built from source they can read.
#
# wimboot comes from the iPXE project's releases; its licence and
# attribution are recorded in THIRD_PARTY_NOTICES.md.
#
# These binaries are the FIRST code a target machine executes over the
# network. That is why this script records a checksum for everything it
# stages, and refuses a silent unverified download.
# =====================================================================
set -Eeuo pipefail

export FORGE_SCRIPT_NAME="download-ipxe-assets.sh"
# shellcheck source=bootstrap/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../bootstrap" && pwd)/lib/common.sh"
forge_enable_traps

SOURCE="distro"
BUILD_REF=""
WIMBOOT_VERSION="v2.8.0"
WIMBOOT_SHA256="${FORGE_WIMBOOT_SHA256:-}"
SKIP_WIMBOOT=false

usage() {
    cat <<'USAGE'
Usage: ./scripts/download-ipxe-assets.sh [OPTIONS]

Stages undionly.kpxe, ipxe.efi and wimboot into the TFTP and HTTP roots.

Options:
  --build            compile iPXE from source instead of using packages
  --ref TAG          iPXE git tag to build       (default from config)
  --wimboot VERSION  wimboot release to fetch    (default v2.8.0)
  --skip-wimboot     do not fetch wimboot (Ubuntu-only deployments)
  -h, --help         this message

Set FORGE_WIMBOOT_SHA256 to require a specific wimboot digest. Without
it the script downloads and then reports the observed digest so it can
be pinned -- it never claims a download was verified when it was not.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build)        SOURCE="build"; shift ;;
        --ref)          BUILD_REF="${2:?}"; shift 2 ;;
        --wimboot)      WIMBOOT_VERSION="${2:?}"; shift 2 ;;
        --skip-wimboot) SKIP_WIMBOOT=true; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              log_err "unknown option: $1"; usage; exit 2 ;;
    esac
done

stage_from_packages() {
    log_step "Staging iPXE from the distribution packages"

    local -a wanted=(
        "/usr/lib/ipxe/undionly.kpxe:undionly.kpxe:legacy BIOS PXE"
        "/usr/lib/ipxe/ipxe.efi:ipxe.efi:UEFI x86-64"
        "/usr/lib/ipxe/ipxe32.efi:ipxe32.efi:UEFI IA32"
    )
    local found=0 entry source destination description

    for entry in "${wanted[@]}"; do
        IFS=: read -r source destination description <<< "$entry"
        if [[ -f "$source" ]]; then
            install -m 0644 "$source" "$TFTP_ROOT/$destination"
            install -m 0644 "$source" "$HTTP_ROOT/ipxe/$destination"
            log_ok "$(printf '%-16s' "$destination") $description"
            found=$((found + 1))
        else
            log_dim "$(printf '%-16s' "$destination") not in this installation ($source)"
        fi
    done

    if [[ $found -eq 0 ]]; then
        log_err "no iPXE binary found under /usr/lib/ipxe"
        log_dim "install the packages:"
        log_dim "  sudo apt-get install -y ipxe ipxe-qemu"
        log_dim "or build from source:"
        log_dim "  $0 --build"
        exit 1
    fi
    log_ok "$found binary/binaries staged from signed distribution packages"
}

stage_from_source() {
    local ref="${BUILD_REF:-$(forge_config '.pxe.ipxe.build_ref')}"
    [[ -n "$ref" ]] || ref="v1.21.1"

    log_step "Building iPXE from source at $ref"
    log_warn "this compiles code that will run before any operating system"
    log_dim "read what you are building: https://github.com/ipxe/ipxe/tree/$ref"

    require_commands git make gcc

    local build_dir="${FORGE_BUILD_DIR:-$(mktemp -d)}"
    log "build directory: $build_dir"

    if [[ ! -d "$build_dir/ipxe/.git" ]]; then
        # --depth 1 on the tag: the full history is 300 MB and is not
        # needed to build one tagged release.
        git clone --depth 1 --branch "$ref" https://github.com/ipxe/ipxe.git "$build_dir/ipxe"
    fi

    local commit
    commit=$(git -C "$build_dir/ipxe" rev-parse HEAD)
    log_ok "building from commit $commit"

    # A general.h override enabling the commands the boot scripts use.
    # Without NSLOOKUP/PING/CONSOLE the rescue menu is much less useful.
    cat > "$build_dir/ipxe/src/config/local/general.h" <<'CONFIG'
/* FORGE-AI iPXE build options */
#define IMAGE_TRUST_CMD     /* imgtrust, for signed image verification */
#define PING_CMD            /* ping, for the rescue menu               */
#define NSLOOKUP_CMD        /* nslookup                                */
#define CONSOLE_CMD         /* console configuration                   */
#define REBOOT_CMD          /* reboot, used by the fallback menu       */
#define POWEROFF_CMD
#define NTP_CMD
#define VLAN_CMD
#define PARAM_CMD           /* params/param, used for state callbacks  */
#define DIGEST_CMD          /* sha256sum inside iPXE                   */
CONFIG

    ( cd "$build_dir/ipxe/src" && make -j"$(nproc)" bin/undionly.kpxe bin-x86_64-efi/ipxe.efi )

    install -m 0644 "$build_dir/ipxe/src/bin/undionly.kpxe" "$TFTP_ROOT/undionly.kpxe"
    install -m 0644 "$build_dir/ipxe/src/bin-x86_64-efi/ipxe.efi" "$TFTP_ROOT/ipxe.efi"
    install -m 0644 "$build_dir/ipxe/src/bin/undionly.kpxe" "$HTTP_ROOT/ipxe/undionly.kpxe"
    install -m 0644 "$build_dir/ipxe/src/bin-x86_64-efi/ipxe.efi" "$HTTP_ROOT/ipxe/ipxe.efi"

    log_ok "built and staged undionly.kpxe and ipxe.efi from $ref ($commit)"
    printf '%s\n' "$commit" > "$TFTP_ROOT/.ipxe-commit"
}

stage_wimboot() {
    [[ "$SKIP_WIMBOOT" == false ]] || {
        log_step "Skipping wimboot"
        log_dim "--skip-wimboot: only the Ubuntu target can be provisioned"
        return 0
    }

    log_step "Staging wimboot $WIMBOOT_VERSION"
    local url="https://github.com/ipxe/wimboot/releases/download/${WIMBOOT_VERSION}/wimboot"
    local target="$HTTP_ROOT/wimboot/wimboot"

    mkdir -p "$(dirname "$target")"

    if [[ -f "$target" ]]; then
        local existing; existing=$(sha256sum "$target" | cut -d' ' -f1)
        if [[ -n "$WIMBOOT_SHA256" && "$existing" == "$WIMBOOT_SHA256" ]]; then
            log_ok "already staged and matches the pinned digest"
            return 0
        fi
        if [[ -z "$WIMBOOT_SHA256" ]]; then
            log_ok "already staged (unpinned)"
            log_dim "SHA-256: $existing"
            return 0
        fi
        log_warn "the staged wimboot does not match the pinned digest; re-downloading"
    fi

    log "downloading $url"
    if ! curl -fL --progress-bar -o "$target" "$url"; then
        log_err "could not download wimboot"
        log_dim "the Windows target cannot be provisioned without it"
        log_dim "download it by hand and place it at $target"
        exit 1
    fi
    chmod 0644 "$target"

    local observed; observed=$(sha256sum "$target" | cut -d' ' -f1)
    if [[ -n "$WIMBOOT_SHA256" ]]; then
        if [[ "$observed" != "$WIMBOOT_SHA256" ]]; then
            log_err "wimboot checksum mismatch"
            log_dim "  expected $WIMBOOT_SHA256"
            log_dim "  observed $observed"
            rm -f "$target"
            log_dim "the file has been removed rather than left for something to boot"
            exit 1
        fi
        log_ok "wimboot verified against the pinned digest"
    else
        log_warn "wimboot was downloaded WITHOUT verification"
        log_dim "SHA-256: $observed"
        log_dim "this is the first code the Windows target executes over the network."
        log_dim "Pin it so a later change is detected:"
        log_dim "  export FORGE_WIMBOOT_SHA256=$observed"
        log_dim "  wimboot_sha256: \"$observed\"   # ansible/roles/windows_winpe/defaults/main.yml"
    fi
}

record_checksums() {
    log_step "Recording checksums"
    local manifest="$TFTP_ROOT/checksums.sha256"
    : > "$manifest"

    local artefact
    for artefact in "$TFTP_ROOT"/*.kpxe "$TFTP_ROOT"/*.efi "$HTTP_ROOT/wimboot/wimboot"; do
        [[ -f "$artefact" ]] || continue
        ( cd "$(dirname "$artefact")" && sha256sum "$(basename "$artefact")" ) >> "$manifest"
    done

    chmod 0644 "$manifest"
    log_ok "wrote $manifest"
    sed 's/^/       /' "$manifest" >&2
}

main() {
    forge_require_valid_config
    require_commands curl sha256sum install

    TFTP_ROOT=$(forge_config '.storage.tftp_root')
    HTTP_ROOT=$(forge_config '.storage.http_root')
    mkdir -p "$TFTP_ROOT" "$HTTP_ROOT/ipxe" "$HTTP_ROOT/wimboot"

    case "$SOURCE" in
        distro) stage_from_packages ;;
        build)  stage_from_source ;;
    esac

    stage_wimboot
    record_checksums

    log_step "Done"
    cat >&2 <<SUMMARY

  TFTP root  $TFTP_ROOT        (served by dnsmasq, stage 1 only)
  HTTP root  $HTTP_ROOT/ipxe   (served for UEFI HTTP Boot)

  Only these small binaries travel over TFTP. Everything large -- kernels,
  initrds, WIMs, the Ubuntu ISO -- moves over HTTP, because TFTP's
  lock-step acknowledgement makes multi-megabyte transfers slow and fragile.

  Next: make deploy-pxe

SUMMARY
}

main "$@"
