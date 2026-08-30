#!/usr/bin/env bash
# =====================================================================
# FORGE-AI :: install the host packages
# =====================================================================
# Installs what check-prerequisites.sh reports as missing. Idempotent:
# safe to run repeatedly.
#
#   ./bootstrap/prepare-host.sh
#   ./bootstrap/prepare-host.sh --install-docker
#   ./bootstrap/prepare-host.sh --dry-run
#
# Docker is behind an explicit flag on purpose. Installing a container
# runtime rewrites the host's iptables rules and adds a daemon that runs
# as root; that is not something to do to someone's machine as a side
# effect of "prepare the host".
#
# There is no curl-pipe-shell anywhere in this script. Docker is
# installed from the official APT repository with its GPG key verified,
# which is the method Docker documents for exactly this reason.
# =====================================================================
set -Eeuo pipefail

export FORGE_SCRIPT_NAME="prepare-host.sh"
# shellcheck source=bootstrap/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
forge_enable_traps

INSTALL_DOCKER=false
INSTALL_PYTHON=true
DRY_RUN=false
ADD_USER_GROUPS=true

usage() {
    cat <<'USAGE'
Usage: ./bootstrap/prepare-host.sh [OPTIONS]

Installs the packages FORGE-AI needs on an Ubuntu 24.04 host.

Options:
  --install-docker   also install Docker Engine and the compose plugin
                     from the official Docker APT repository
  --no-python        skip the Python virtual environment and Ansible
  --no-groups        do not add the invoking user to libvirt/kvm
  --dry-run          print what would be installed, change nothing
  -h, --help         this message

Docker is opt-in because installing a container runtime rewrites the
host's iptables rules and adds a root daemon. That should be a decision,
not a side effect.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-docker) INSTALL_DOCKER=true; shift ;;
        --no-python)      INSTALL_PYTHON=false; shift ;;
        --no-groups)      ADD_USER_GROUPS=false; shift ;;
        --dry-run)        DRY_RUN=true; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                log_err "unknown option: $1"; usage; exit 2 ;;
    esac
done

# The invoking user, even when the script runs under sudo.
TARGET_USER="${SUDO_USER:-$(id -un)}"

run() {
    if [[ "$DRY_RUN" == true ]]; then
        printf '%s  would run:%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2
        return 0
    fi
    "$@"
}

as_root() {
    if [[ $EUID -eq 0 ]]; then
        run "$@"
    else
        run sudo "$@"
    fi
}

# ---------------------------------------------------------------------
# Package sets
# ---------------------------------------------------------------------
readonly -a PACKAGES_VIRTUALISATION=(
    qemu-kvm
    qemu-utils
    libvirt-daemon-system
    libvirt-clients
    virtinst
    ovmf                 # UEFI firmware for the guests
    bridge-utils
)

readonly -a PACKAGES_PROVISIONING=(
    dnsmasq              # DHCP, DNS and TFTP on the provisioning bridge
    ipxe                 # undionly.kpxe for legacy BIOS clients
    ipxe-qemu            # ipxe.efi for UEFI clients
    p7zip-full           # extract ISO contents without a loop mount
    wimtools             # read and edit WIM images on Linux (no DISM)
    genisoimage
    xorriso
    cabextract
)

readonly -a PACKAGES_TOOLING=(
    curl
    jq
    git
    rsync
    ca-certificates
    gnupg
    openssl
    whois                # mkpasswd, for the autoinstall password hash
    smbclient            # verify the Windows media SMB export
    net-tools
    tcpdump              # the DHCP conflict probe depends on this
    libxml2-utils        # xmllint, used to validate Autounattend.xml
    python3
    python3-venv
    python3-pip
    python3-lxml
    python3-libvirt
    make
    # libvirt-python is published to PyPI as a source distribution only --
    # there is no wheel -- so `pip install -r requirements-python.txt`
    # compiles it, and that needs libvirt.pc (libvirt-dev), pkg-config,
    # the Python headers and a compiler. Without these the bootstrap
    # fails partway through on a host that has everything else it needs,
    # with a pkg-config error that says nothing about which package to
    # install. Found on a fresh Ubuntu Server 24.04.
    pkg-config
    libvirt-dev
    python3-dev
    gcc
)

check_distribution() {
    log_step "Checking the distribution"
    [[ -r /etc/os-release ]] || die "/etc/os-release is unreadable"
    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        log_err "this script installs Ubuntu packages; this host is ${PRETTY_NAME:-unknown}"
        log_dim "the equivalent package names for other distributions are in docs/COMPATIBILITY.md"
        die "unsupported distribution"
    fi
    if [[ "${VERSION_ID:-}" != "24.04" ]]; then
        log_warn "validated on Ubuntu 24.04 LTS; this host is ${VERSION_ID:-unknown}"
        log_dim "package names and OVMF paths may differ -- see docs/COMPATIBILITY.md"
        confirm "Continue anyway?" || die "aborted"
    fi
    log_ok "${PRETTY_NAME:-Ubuntu ${VERSION_ID:-}}"
}

install_packages() {
    log_step "Installing the host packages"
    local -a packages=(
        "${PACKAGES_VIRTUALISATION[@]}"
        "${PACKAGES_PROVISIONING[@]}"
        "${PACKAGES_TOOLING[@]}"
    )
    log "${#packages[@]} packages: virtualisation, provisioning and tooling"
    as_root apt-get update -qq
    # DEBIAN_FRONTEND keeps a package's post-install script from opening
    # a dialog on a non-interactive run.
    as_root env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends "${packages[@]}"
    log_ok "host packages installed"
}

enable_libvirt() {
    log_step "Enabling libvirtd"
    as_root systemctl enable --now libvirtd
    # The packaged dnsmasq binds every interface. FORGE-AI runs its own
    # instance bound only to the provisioning bridge, so the packaged
    # one is disabled to keep two DHCP servers off the same segment.
    if systemctl is-enabled dnsmasq >/dev/null 2>&1; then
        log_warn "disabling the packaged dnsmasq service"
        log_dim "FORGE-AI runs a dedicated instance bound only to the provisioning bridge;"
        log_dim "two DHCP servers on one segment make PXE fail intermittently"
        as_root systemctl disable --now dnsmasq || true
    fi
    log_ok "libvirtd is running"
}

add_user_groups() {
    [[ "$ADD_USER_GROUPS" == true ]] || return 0
    log_step "Granting $TARGET_USER access to libvirt and KVM"
    as_root usermod -aG libvirt,kvm "$TARGET_USER"
    log_ok "$TARGET_USER added to libvirt and kvm"
    log_warn "group membership only takes effect in a NEW login session"
    log_dim "log out and back in, or run: newgrp libvirt"
}

install_docker() {
    [[ "$INSTALL_DOCKER" == true ]] || {
        log_step "Skipping Docker"
        log_dim "pass --install-docker to install Docker Engine and the compose plugin"
        return 0
    }

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        log_ok "Docker and the compose plugin are already installed"
        return 0
    fi

    log_step "Installing Docker Engine from the official repository"
    log_warn "this rewrites the host's iptables rules and adds a root daemon"

    # The GPG key is fetched and verified, then the repository is added
    # with signed-by pinned to that key. No curl | sh.
    as_root install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        log "fetching the Docker GPG key"
        run bash -c 'curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | sudo tee /etc/apt/keyrings/docker.asc >/dev/null'
        as_root chmod a+r /etc/apt/keyrings/docker.asc
    fi

    local codename
    codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
    local arch; arch=$(dpkg --print-architecture)

    run bash -c "echo 'deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu ${codename} stable' \
        | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null"

    as_root apt-get update -qq
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    as_root systemctl enable --now docker
    as_root usermod -aG docker "$TARGET_USER"

    log_ok "Docker installed"
    log_warn "$TARGET_USER was added to the 'docker' group"
    log_dim "membership in that group is equivalent to root on this host"
    log_dim "it takes effect in a new login session"
}

install_python_environment() {
    [[ "$INSTALL_PYTHON" == true ]] || {
        log_step "Skipping the Python environment"
        return 0
    }

    log_step "Creating the Python virtual environment"
    local venv="$FORGE_ROOT/.venv"

    if [[ -d "$venv" ]]; then
        log_ok "$venv already exists"
    else
        run python3 -m venv "$venv"
        log_ok "created $venv"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_dim "would install ansible/requirements-python.txt into $venv"
        return 0
    fi

    log "installing the Python requirements"
    # Nothing is installed into the system Python: the virtual
    # environment keeps this from fighting with apt-managed packages.
    "$venv/bin/pip" install --quiet --upgrade pip
    "$venv/bin/pip" install --quiet -r "$FORGE_ROOT/ansible/requirements-python.txt"
    log_ok "Python requirements installed into $venv"

    log "installing the Ansible collections"
    if "$venv/bin/ansible-galaxy" collection install \
            -r "$FORGE_ROOT/ansible/requirements.yml" \
            -p "$FORGE_ROOT/ansible/collections" >/dev/null 2>&1; then
        log_ok "collections installed into ansible/collections/"
    else
        log_warn "could not reach Ansible Galaxy"
        log_dim "if this host has no route to galaxy.ansible.com, install the bundled"
        log_dim "distribution instead, which ships the same collections:"
        log_dim "  $venv/bin/pip install 'ansible>=10,<13'"
    fi
}

summary() {
    log_step "Done"
    cat >&2 <<SUMMARY

  Installed:
    virtualisation : qemu-kvm, libvirt, virtinst, OVMF
    provisioning   : dnsmasq, ipxe, wimtools, p7zip
    tooling        : curl, jq, tcpdump, smbclient, xmllint, whois
    docker         : $([[ "$INSTALL_DOCKER" == true ]] && echo "yes" || echo "no (pass --install-docker)")
    python         : $([[ "$INSTALL_PYTHON" == true ]] && echo "$FORGE_ROOT/.venv" || echo "skipped")

  Next:
    1. log out and back in, so the libvirt/kvm group membership applies
    2. ./bootstrap/check-prerequisites.sh
    3. ./bootstrap/bootstrap.sh

SUMMARY
}

main() {
    forge_banner
    [[ "$DRY_RUN" == true ]] && log_warn "dry run: nothing will be changed"

    check_distribution
    have_sudo || die "sudo access is required"

    install_packages
    enable_libvirt
    add_user_groups
    install_docker
    install_python_environment
    summary
}

main "$@"
