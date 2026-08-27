#!/usr/bin/env bash
# =====================================================================
# FORGE-AI :: tear the PoC down
# =====================================================================
#   ./scripts/destroy.sh                        VMs, PXE, network
#   ./scripts/destroy.sh --media                also the prepared media
#   ./scripts/destroy.sh --all                  also the control plane
#   ./scripts/destroy.sh --all --volumes        also Gitea/Semaphore data
#
# Destruction is never implicit. The script prints exactly what it will
# remove, then requires the confirmation token from config/poc.yml to be
# typed. Ansible checks the same token again, because a shell prompt is
# not a security boundary.
#
# Deployment reports are NEVER removed: they are the audit trail.
# =====================================================================
set -Eeuo pipefail

export FORGE_SCRIPT_NAME="destroy.sh"
# shellcheck source=bootstrap/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../bootstrap" && pwd)/lib/common.sh"
forge_enable_traps

DESTROY_MEDIA=false
DESTROY_CONTROL_PLANE=false
DESTROY_VOLUMES=false
ASSUME_YES=false

usage() {
    cat <<'USAGE'
Usage: ./scripts/destroy.sh [OPTIONS]

Removes the PoC. By default: the target VMs and their disks, the PXE
services and the provisioning network.

Options:
  --media      also remove the prepared media and boot artefacts
               (the downloaded ISOs are kept -- re-downloading several
               gigabytes is rarely what anyone wants)
  --all        also remove the Docker control plane
  --volumes    with --all, also remove its volumes.
               THIS DESTROYS the Gitea repositories and the entire
               Semaphore task history.
  --yes        skip the interactive confirmation (still needs the token
               via FORGE_ASSUME_YES for the underlying playbook)
  -h, --help   this message

Deployment reports under storage.report_dir are never removed.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --media)    DESTROY_MEDIA=true; shift ;;
        --all)      DESTROY_CONTROL_PLANE=true; shift ;;
        --volumes)  DESTROY_VOLUMES=true; shift ;;
        --yes)      ASSUME_YES=true; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          log_err "unknown option: $1"; usage; exit 2 ;;
    esac
done

if [[ "$DESTROY_VOLUMES" == true && "$DESTROY_CONTROL_PLANE" == false ]]; then
    log_err "--volumes only makes sense with --all"
    exit 2
fi

main() {
    forge_require_valid_config
    require_commands "$FORGE_ANSIBLE_PLAYBOOK" jq

    local token report_dir iso_dir
    token=$(forge_config '.safety.destroy_confirmation_token')
    report_dir=$(forge_config '.storage.report_dir')
    iso_dir=$(forge_config '.storage.iso_dir')

    forge_banner
    log_step "About to destroy the '$(forge_config '.deployment.name')' PoC"

    printf '\n' >&2
    printf '  %sWill be removed:%s\n' "$C_RED" "$C_RESET" >&2
    local name address disk_gb
    while IFS=$'\t' read -r name address disk_gb; do
        printf '    VM   %-16s %-16s %s GB disk\n' "$name" "$address" "$disk_gb" >&2
    done < <(forge_config_json | jq -r '.hosts[] | [.name, .ip_address, .disk_gb] | @tsv')
    printf '    svc  %s\n' "$(forge_config '.provisioning_network.name') (libvirt network)" >&2
    printf '    svc  forge-dnsmasq (DHCP/DNS/TFTP)\n' >&2
    [[ "$DESTROY_MEDIA" == true ]] && \
        printf '    dir  %s  (prepared media and boot artefacts)\n' "$(forge_config '.storage.http_root')" >&2
    if [[ "$DESTROY_CONTROL_PLANE" == true ]]; then
        printf '    ctr  the Docker control plane (Gitea, Semaphore, PostgreSQL, boot server)\n' >&2
        [[ "$DESTROY_VOLUMES" == true ]] && \
            printf '    %sVOL  Docker volumes -- Gitea repositories and Semaphore history%s\n' "$C_RED" "$C_RESET" >&2
    fi

    printf '\n  %sWill be kept:%s\n' "$C_GREEN" "$C_RESET" >&2
    printf '    %s  (deployment reports -- the audit trail)\n' "$report_dir" >&2
    printf '    %s  (downloaded ISOs)\n' "$iso_dir" >&2
    [[ "$DESTROY_MEDIA" == false ]] && printf '    %s  (prepared media)\n' "$(forge_config '.storage.http_root')" >&2
    [[ "$DESTROY_CONTROL_PLANE" == false ]] && printf '    the Docker control plane -- still running\n' >&2
    printf '\n' >&2

    if [[ "$ASSUME_YES" == false ]]; then
        confirm "This cannot be undone." "$token" || die "not confirmed; nothing was changed"
    else
        log_warn "--yes: proceeding without an interactive confirmation"
    fi

    log_step "Destroying"
    local -a command=(
        "$FORGE_ANSIBLE_PLAYBOOK" playbooks/destroy-poc.yml
        -e "confirm_destroy=$token"
        -e "destroy_media=$DESTROY_MEDIA"
        -e "destroy_control_plane=$DESTROY_CONTROL_PLANE"
        -e "destroy_volumes=$DESTROY_VOLUMES"
    )
    [[ -f "$FORGE_ROOT/.vault-password" ]] && command+=(--vault-password-file "$FORGE_ROOT/.vault-password")

    ( cd "$FORGE_ROOT/ansible" && "${command[@]}" )

    log_step "Done"
    cat >&2 <<SUMMARY

  Rebuild with:
    make bootstrap
    make prepare-media
    make provision
    make validate

  Or the whole lifecycle:
    make deploy

SUMMARY
}

main "$@"
