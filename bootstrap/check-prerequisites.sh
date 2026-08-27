#!/usr/bin/env bash
# =====================================================================
# FORGE-AI :: prerequisite check
# =====================================================================
# Read-only. Answers "can this host run the PoC?" before anything is
# installed, downloaded or created.
#
#   ./bootstrap/check-prerequisites.sh
#   ./bootstrap/check-prerequisites.sh --verbose
#   ./bootstrap/check-prerequisites.sh --json
#
# Exit codes:
#   0  ready
#   1  at least one blocking problem
#   2  the script itself could not run
# =====================================================================
set -Eeuo pipefail

# Consumed by the error trap in lib/common.sh.
export FORGE_SCRIPT_NAME="check-prerequisites.sh"
# shellcheck source=bootstrap/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
forge_enable_traps

VERBOSE=false
JSON_OUTPUT=false

usage() {
    cat <<'USAGE'
Usage: ./bootstrap/check-prerequisites.sh [OPTIONS]

Read-only validation that this host can run the FORGE-AI PoC. Installs
nothing and changes nothing.

Options:
  --verbose   show the observed value for every check, not just failures
  --json      machine-readable output
  -h, --help  this message

Exit codes:
  0  ready
  1  at least one blocking problem
  2  the script itself could not run
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v) VERBOSE=true; shift ;;
        --json)       JSON_OUTPUT=true; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            log_err "unknown option: $1"; usage; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------
# Result accumulation
# ---------------------------------------------------------------------
declare -a CHECK_NAMES=() CHECK_STATUS=() CHECK_DETAIL=() CHECK_HINT=()
ERRORS=0
WARNINGS=0

record() {
    local name=$1 status=$2 detail=$3 hint=${4:-}
    CHECK_NAMES+=("$name"); CHECK_STATUS+=("$status")
    CHECK_DETAIL+=("$detail"); CHECK_HINT+=("$hint")
    case "$status" in
        error) ERRORS=$((ERRORS + 1)) ;;
        warn)  WARNINGS=$((WARNINGS + 1)) ;;
    esac
    if [[ "$JSON_OUTPUT" == false ]]; then
        case "$status" in
            ok)    [[ "$VERBOSE" == true ]] && log_ok "$name: $detail" ;;
            warn)  log_warn "$name: $detail"; [[ -n "$hint" ]] && log_dim "$hint" ;;
            error) log_err "$name: $detail";  [[ -n "$hint" ]] && log_dim "$hint" ;;
        esac
    fi
    return 0
}

# ---------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------
check_operating_system() {
    if [[ ! -r /etc/os-release ]]; then
        record os "error" "/etc/os-release is unreadable; cannot identify the distribution"
        return
    fi
    # shellcheck disable=SC1091   # runtime file, not in the repository
    source /etc/os-release
    local id=${ID:-unknown} version=${VERSION_ID:-unknown}

    if [[ "$id" == "ubuntu" && "$version" == "24.04" ]]; then
        record os "ok" "Ubuntu $version (${VERSION_CODENAME:-noble})"
    elif [[ "$id" == "ubuntu" ]]; then
        record os "warn" "Ubuntu $version" \
            "validated on 24.04 LTS only (docs/COMPATIBILITY.md); package names and OVMF paths may differ"
    else
        record os "error" "${PRETTY_NAME:-$id $version}" \
            "FORGE-AI is validated on Ubuntu 24.04 LTS x86_64. See docs/COMPATIBILITY.md."
    fi

    local arch; arch=$(uname -m)
    if [[ "$arch" == "x86_64" ]]; then
        record architecture "ok" "$arch"
    else
        record architecture "error" "$arch" \
            "the boot chain (iPXE x86_64, OVMF, Windows amd64) targets x86_64 only"
    fi
}

check_privileges() {
    if [[ $EUID -eq 0 ]]; then
        record privileges "ok" "running as root"
    elif sudo -n true 2>/dev/null; then
        record privileges "ok" "passwordless sudo available"
    elif sudo -v 2>/dev/null; then
        record privileges "ok" "sudo available (password accepted)"
    else
        record privileges "error" "no root or sudo access" \
            "libvirt, dnsmasq, /srv and Docker all need it"
    fi
}

check_virtualisation() {
    local flags
    flags=$(grep -cE '(vmx|svm)' /proc/cpuinfo || true)
    if [[ "$flags" -gt 0 ]]; then
        local kind="unknown"
        grep -q vmx /proc/cpuinfo && kind="Intel VT-x"
        grep -q svm /proc/cpuinfo && kind="AMD-V"
        record cpu-virtualisation "ok" "$kind on $flags thread(s)"
    else
        record cpu-virtualisation "error" "no vmx/svm flag in /proc/cpuinfo" \
            "enable VT-x/AMD-V in firmware. Inside a VM, enable nested virtualisation on the hypervisor."
    fi

    if [[ -c /dev/kvm ]]; then
        if [[ -w /dev/kvm ]]; then
            record dev-kvm "ok" "/dev/kvm present and writable"
        else
            record dev-kvm "error" "/dev/kvm exists but is not writable by $(id -un)" \
                "sudo usermod -aG kvm,libvirt \$USER   then log out and back in"
        fi
    else
        record dev-kvm "error" "/dev/kvm is missing" \
            "sudo apt-get install -y qemu-kvm   (and check the CPU virtualisation flag above)"
    fi
}

check_memory() {
    local total_kb total_mb required_mb
    total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    total_mb=$((total_kb / 1024))

    # Read the requirement from the configuration when it is readable,
    # so the check reflects the hosts actually configured.
    required_mb=$(forge_config '[.hosts[].memory_mb] | add' 2>/dev/null || echo "")
    if [[ -z "$required_mb" || "$required_mb" == "0" ]]; then
        required_mb=12288
        local source="default"
    else
        required_mb=$((required_mb + 4096))
        local source="config/poc.yml targets + 4096 MB control plane"
    fi

    if [[ "$total_mb" -ge "$required_mb" ]]; then
        record memory "ok" "${total_mb} MB present, ${required_mb} MB needed ($source)"
    else
        record memory "error" "${total_mb} MB present, ${required_mb} MB needed ($source)" \
            "reduce hosts[].memory_mb in config/poc.yml, or deploy the Ubuntu target only"
    fi
}

check_disk() {
    local target="/srv" available required
    [[ -d "$target" ]] || target="/"
    available=$(df -BG --output=avail "$target" | tail -1 | tr -dc '0-9')

    required=$(forge_config '[.hosts[].disk_gb] | add' 2>/dev/null || echo "")
    if [[ -z "$required" || "$required" == "0" ]]; then
        required=180
        local source="default"
    else
        required=$((required + 60))
        local source="config/poc.yml targets + 60 GB media"
    fi

    if [[ "$available" -ge "$required" ]]; then
        record disk "ok" "${available} GB free on $target, ${required} GB needed ($source)"
    else
        record disk "error" "${available} GB free on $target, ${required} GB needed ($source)" \
            "qcow2 images are sparse, so the real usage is lower -- but Windows media alone needs ~15 GB extracted"
    fi
}

check_cpu_count() {
    local cores; cores=$(nproc)
    if [[ "$cores" -ge 4 ]]; then
        record cpu-cores "ok" "$cores"
    else
        record cpu-cores "warn" "$cores (4 recommended)" \
            "installations will work but will be slow"
    fi
}

check_commands() {
    local -a required=(curl jq git python3 awk sed grep)
    local -a virtualisation=(virsh virt-install qemu-img)
    local -a provisioning=(dnsmasq 7z wimlib-imagex)
    local -a container=(docker)
    local name

    for name in "${required[@]}"; do
        if command -v "$name" >/dev/null 2>&1; then
            record "cmd:$name" "ok" "$(command -v "$name")"
        else
            record "cmd:$name" "error" "not on PATH" "sudo apt-get install -y $name"
        fi
    done

    for name in "${virtualisation[@]}"; do
        if command -v "$name" >/dev/null 2>&1; then
            record "cmd:$name" "ok" "$(command -v "$name")"
        else
            record "cmd:$name" "error" "not on PATH" \
                "./bootstrap/prepare-host.sh installs qemu-kvm, libvirt-daemon-system and virtinst"
        fi
    done

    for name in "${provisioning[@]}"; do
        if command -v "$name" >/dev/null 2>&1; then
            record "cmd:$name" "ok" "$(command -v "$name")"
        else
            local package="$name"
            [[ "$name" == "7z" ]] && package="p7zip-full"
            [[ "$name" == "wimlib-imagex" ]] && package="wimtools"
            record "cmd:$name" "warn" "not on PATH" \
                "needed to unpack installation media: sudo apt-get install -y $package"
        fi
    done

    for name in "${container[@]}"; do
        if command -v "$name" >/dev/null 2>&1; then
            record "cmd:$name" "ok" "$(command -v "$name")"
        else
            record "cmd:$name" "error" "not on PATH" \
                "./bootstrap/prepare-host.sh --install-docker installs it from the official Docker repository"
        fi
    done

    if docker compose version >/dev/null 2>&1; then
        record docker-compose "ok" "$(docker compose version --short 2>/dev/null || echo present)"
    else
        record docker-compose "error" "the compose v2 plugin is not available" \
            "the standalone docker-compose v1 is not supported; install docker-compose-plugin"
    fi
}

check_libvirt() {
    if ! command -v virsh >/dev/null 2>&1; then
        record libvirt "error" "virsh is not installed" "./bootstrap/prepare-host.sh"
        return
    fi
    local version
    if version=$(virsh --connect qemu:///system version 2>&1); then
        record libvirt "ok" "$(printf '%s' "$version" | head -1)"
    elif version=$(sudo -n virsh --connect qemu:///system version 2>&1); then
        record libvirt "warn" "reachable only with sudo" \
            "sudo usermod -aG libvirt \$USER   then log out and back in"
    else
        record libvirt "error" "cannot reach qemu:///system" \
            "sudo systemctl enable --now libvirtd"
    fi
}

check_uefi_firmware() {
    local -a candidates=(
        /usr/share/OVMF/OVMF_CODE_4M.fd
        /usr/share/OVMF/OVMF_CODE.fd
        /usr/share/ovmf/OVMF.fd
    )
    local path
    for path in "${candidates[@]}"; do
        if [[ -r "$path" ]]; then
            record ovmf "ok" "$path"
            return
        fi
    done
    record ovmf "error" "no OVMF firmware found" \
        "both PoC targets default to UEFI: sudo apt-get install -y ovmf"
}

check_dhcp_conflict() {
    local bridge
    bridge=$(forge_config '.provisioning_network.bridge' 2>/dev/null || echo "")
    [[ -z "$bridge" ]] && bridge="virbr-forge"

    if [[ ! -d "/sys/class/net/$bridge" ]]; then
        record dhcp-conflict "ok" "bridge $bridge does not exist yet" \
            "it will be created isolated from the host LAN, which is what makes this safe"
        return
    fi

    if ! command -v tcpdump >/dev/null 2>&1; then
        record dhcp-conflict "warn" "tcpdump is not installed, so no passive probe was possible" \
            "sudo apt-get install -y tcpdump   -- running a second DHCP server on a network that already has one is the most damaging mistake this project can make"
        return
    fi

    local capture
    capture=$(timeout 10 sudo -n tcpdump -i "$bridge" -n -c 5 --immediate-mode \
                  'udp port 67 or udp port 68' 2>&1 || true)

    local gateway; gateway=$(forge_config '.provisioning_network.gateway' 2>/dev/null || echo "")
    local foreign
    foreign=$(printf '%s' "$capture" \
              | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}\.(67|bootps)' \
              | sed 's/\.\(67\|bootps\)$//' \
              | grep -v "^${gateway}$" | sort -u | tr '\n' ' ' || true)

    if [[ -n "${foreign// /}" ]]; then
        record dhcp-conflict "error" "another DHCP server answered on $bridge: ${foreign}" \
            "two DHCP servers on one segment make PXE fail intermittently. Investigate with: sudo tcpdump -i $bridge -n 'udp port 67 or udp port 68'"
    else
        record dhcp-conflict "ok" "no competing DHCP server observed on $bridge"
    fi
}

check_ports() {
    local gateway; gateway=$(forge_config '.provisioning_network.gateway' 2>/dev/null || echo "192.168.250.1")
    local -a ports=("8080/tcp:boot server" "69/udp:TFTP" "445/tcp:SMB media export")
    local entry port proto service holder

    for entry in "${ports[@]}"; do
        port="${entry%%/*}"
        proto="${entry#*/}"; proto="${proto%%:*}"
        service="${entry##*:}"
        local flag="t"; [[ "$proto" == "udp" ]] && flag="u"

        holder=$(ss -Hln"${flag}"p "sport = :$port" 2>/dev/null | head -1 || true)
        if [[ -n "$holder" ]]; then
            record "port:$port/$proto" "warn" "already in use ($service)" \
                "if this is a previous FORGE-AI run, fine. Otherwise: sudo ss -lntup | grep :$port"
        else
            record "port:$port/$proto" "ok" "free for the $service on $gateway"
        fi
    done
}

check_configuration() {
    if [[ ! -f "$FORGE_ROOT/config/poc.yml" ]]; then
        record configuration "warn" "config/poc.yml does not exist" \
            "cp config/poc.example.yml config/poc.yml   -- the example is used until you do"
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        record configuration "error" "python3 is needed to validate the configuration"
        return
    fi

    local output
    if output=$("$FORGE_ROOT/scripts/validate-config.py" 2>&1); then
        local hosts; hosts=$(forge_config '.hosts | length' 2>/dev/null || echo "?")
        record configuration "ok" "valid, $hosts host(s) defined"
    else
        # Quote the first finding rather than only pointing at the tool:
        # the answer is usually one line long.
        local first_finding
        first_finding=$(printf '%s' "$output" | grep -m1 'ERROR' || echo "see the full output")
        record configuration "error" "the configuration does not validate -- ${first_finding}" \
            "run ./scripts/validate-config.py for every finding"
    fi
}

check_secrets() {
    if [[ -f "$FORGE_ROOT/compose/.env" ]]; then
        if grep -q '=CHANGEME' "$FORGE_ROOT/compose/.env" 2>/dev/null; then
            record secrets "error" "compose/.env still contains placeholder values" \
                "./bootstrap/create-secrets.sh generates real ones"
        else
            local mode; mode=$(stat -c '%a' "$FORGE_ROOT/compose/.env")
            if [[ "$mode" == "600" ]]; then
                record secrets "ok" "compose/.env present, mode $mode"
            else
                record secrets "warn" "compose/.env is mode $mode, expected 600" \
                    "chmod 600 compose/.env"
            fi
        fi
    else
        record secrets "warn" "compose/.env does not exist" \
            "cp compose/.env.example compose/.env && ./bootstrap/create-secrets.sh"
    fi
}

check_media() {
    local ubuntu_iso windows_iso
    ubuntu_iso=$(forge_config '.media.ubuntu.iso_path' 2>/dev/null || echo "")
    windows_iso=$(forge_config '.media.windows.iso_path' 2>/dev/null || echo "")

    if [[ -n "$ubuntu_iso" && -f "$ubuntu_iso" ]]; then
        record media-ubuntu "ok" "$ubuntu_iso ($(du -h "$ubuntu_iso" | cut -f1))"
    else
        record media-ubuntu "warn" "the Ubuntu ISO is not present yet" \
            "make prepare-media   downloads and verifies it"
    fi

    if [[ -z "$windows_iso" ]]; then
        record media-windows "warn" "no Windows ISO configured" \
            "operator-supplied; see docs/WINDOWS-PROVISIONING.md. The Ubuntu target deploys without it."
    elif [[ -f "$windows_iso" ]]; then
        record media-windows "ok" "$windows_iso ($(du -h "$windows_iso" | cut -f1))"
    else
        record media-windows "error" "media.windows.iso_path points at a file that does not exist: $windows_iso"
    fi
}

# ---------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------
emit_json() {
    printf '{\n  "host": "%s",\n  "checked_at": "%s",\n' "$(hostname)" "$(date -Is)"
    printf '  "errors": %d,\n  "warnings": %d,\n' "$ERRORS" "$WARNINGS"
    printf '  "ready": %s,\n  "checks": [\n' "$([[ $ERRORS -eq 0 ]] && echo true || echo false)"
    local i
    for i in "${!CHECK_NAMES[@]}"; do
        [[ $i -gt 0 ]] && printf ',\n'
        printf '    {"name": "%s", "status": "%s", "detail": "%s", "hint": "%s"}' \
            "${CHECK_NAMES[$i]}" "${CHECK_STATUS[$i]}" \
            "$(printf '%s' "${CHECK_DETAIL[$i]}" | sed 's/"/\\"/g')" \
            "$(printf '%s' "${CHECK_HINT[$i]}" | sed 's/"/\\"/g')"
    done
    printf '\n  ]\n}\n'
}

emit_summary() {
    printf '\n' >&2
    printf '%s================================================================%s\n' "$C_BOLD" "$C_RESET" >&2
    if [[ $ERRORS -eq 0 && $WARNINGS -eq 0 ]]; then
        printf '%s READY%s -- %d checks passed\n' "$C_GREEN" "$C_RESET" "${#CHECK_NAMES[@]}" >&2
    elif [[ $ERRORS -eq 0 ]]; then
        printf '%s READY%s -- %d checks, %d warning(s)\n' "$C_GREEN" "$C_RESET" "${#CHECK_NAMES[@]}" "$WARNINGS" >&2
    else
        printf '%s NOT READY%s -- %d error(s), %d warning(s) across %d checks\n' \
            "$C_RED" "$C_RESET" "$ERRORS" "$WARNINGS" "${#CHECK_NAMES[@]}" >&2
    fi
    printf '%s================================================================%s\n' "$C_BOLD" "$C_RESET" >&2

    if [[ $ERRORS -gt 0 ]]; then
        printf '\nFix the errors above, then re-run. To install what is missing:\n' >&2
        printf '  ./bootstrap/prepare-host.sh\n\n' >&2
    else
        printf '\nNext:\n' >&2
        printf '  ./bootstrap/bootstrap.sh          or   make bootstrap\n\n' >&2
    fi
}

main() {
    [[ "$JSON_OUTPUT" == false ]] && forge_banner
    [[ "$JSON_OUTPUT" == false ]] && log_step "Checking prerequisites on $(hostname)"

    check_operating_system
    check_privileges
    check_virtualisation
    check_cpu_count
    check_memory
    check_disk
    check_commands
    check_libvirt
    check_uefi_firmware
    check_configuration
    check_dhcp_conflict
    check_ports
    check_secrets
    check_media

    if [[ "$JSON_OUTPUT" == true ]]; then
        emit_json
    else
        emit_summary
    fi

    [[ $ERRORS -eq 0 ]]
}

main "$@"
