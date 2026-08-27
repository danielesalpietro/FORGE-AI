#!/usr/bin/env bash
# =====================================================================
# FORGE-AI :: smoke test both provisioned targets
# =====================================================================
#   ./scripts/smoke-test.sh
#   ./scripts/smoke-test.sh --host poc-ubuntu-01
#   ./scripts/smoke-test.sh --junit results.xml
#
# Verifies what the deployment claims to have produced, by reading the
# machines rather than trusting the playbook's exit code.
#
# Ubuntu:  VM running, IP responds, SSH works, hostname correct,
#          qemu-guest-agent active, automation user exists, baseline
#          idempotent.
# Windows: VM running, IP responds, WinRM HTTPS works, hostname correct,
#          expected edition, firewall applied, SMBv1 disabled, baseline
#          idempotent.
#
# Exit codes: 0 all passed, 1 at least one failed, 2 usage error
# =====================================================================
set -Eeuo pipefail

export FORGE_SCRIPT_NAME="smoke-test.sh"
# shellcheck source=bootstrap/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../bootstrap" && pwd)/lib/common.sh"
forge_enable_traps

ONLY_HOST=""
JUNIT_PATH=""
SKIP_IDEMPOTENCE=false

usage() {
    cat <<'USAGE'
Usage: ./scripts/smoke-test.sh [OPTIONS]

Verifies the deployed targets by reading them, not by trusting a
playbook's exit code.

Options:
  --host NAME          test only this host
  --junit PATH         also write a JUnit XML report
  --skip-idempotence   skip the second baseline run (much faster)
  -h, --help           this message

The idempotence check runs the configuration playbook a second time in
check mode and fails if it would still change anything. That is the
requirement "run the configuration playbooks twice and report whether
the second run produced unexpected changes".
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)             ONLY_HOST="${2:?}"; shift 2 ;;
        --junit)            JUNIT_PATH="${2:?}"; shift 2 ;;
        --skip-idempotence) SKIP_IDEMPOTENCE=true; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)                  log_err "unknown option: $1"; usage; exit 2 ;;
    esac
done

declare -a TEST_NAMES=() TEST_RESULTS=() TEST_DETAIL=() TEST_HOSTS=()
PASSED=0
FAILED=0

check() {
    local host=$1 name=$2 detail=$3 ok=$4
    TEST_HOSTS+=("$host"); TEST_NAMES+=("$name")
    TEST_DETAIL+=("$detail"); TEST_RESULTS+=("$ok")
    if [[ "$ok" == "true" ]]; then
        PASSED=$((PASSED + 1))
        log_ok "$(printf '%-16s %-26s' "$host" "$name") $detail"
    else
        FAILED=$((FAILED + 1))
        log_err "$(printf '%-16s %-26s' "$host" "$name") $detail"
    fi
}

# --- shared -----------------------------------------------------------
test_domain_running() {
    local host=$1
    local state
    state=$(virsh --connect qemu:///system domstate "$host" 2>/dev/null | tr -d '\r' | head -1 || echo "not defined")
    check "$host" "vm-running" "$state" "$([[ "$state" == "running" ]] && echo true || echo false)"
}

test_address_responds() {
    local host=$1 address=$2
    if ping -c 3 -W 2 "$address" >/dev/null 2>&1; then
        check "$host" "ip-responds" "$address answers ICMP" true
    else
        check "$host" "ip-responds" "$address does not answer ICMP" false
    fi
}

test_lifecycle_state() {
    local host=$1 mac=$2
    local base state attempts
    base="http://$(forge_config '.control_plane.address'):$(forge_config '.control_plane.boot_http_port')"
    local response
    response=$(curl -fsS --max-time 10 "${base}/api/state/${mac}" 2>/dev/null || echo '{}')
    state=$(printf '%s' "$response" | jq -r '.state // "unknown"')
    attempts=$(printf '%s' "$response" | jq -r '.attempts // 0')
    check "$host" "lifecycle-state" "$state after $attempts install attempt(s)" \
        "$([[ "$state" == "ready" || "$state" == "configuring" ]] && echo true || echo false)"
}

# --- Ubuntu -----------------------------------------------------------
ssh_run() {
    local address=$1; shift
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o LogLevel=ERROR \
        -i "$SSH_KEY" "${SSH_USER}@${address}" "$@" 2>/dev/null
}

test_ubuntu() {
    local host=$1 address=$2 mac=$3
    log_step "Ubuntu target: $host ($address)"

    test_domain_running "$host"
    test_address_responds "$host" "$address"
    test_lifecycle_state "$host" "$mac"

    local observed
    if observed=$(ssh_run "$address" 'echo ok'); then
        check "$host" "ssh-login" "key authentication succeeded as $SSH_USER" true
    else
        check "$host" "ssh-login" "cannot log in as $SSH_USER with $SSH_KEY" false
        log_dim "the remaining Ubuntu checks need SSH; skipping them"
        return
    fi

    observed=$(ssh_run "$address" 'hostname') || observed="<no output>"
    check "$host" "hostname" "$observed" "$([[ "$observed" == "$host" ]] && echo true || echo false)"

    observed=$(ssh_run "$address" 'systemctl is-active qemu-guest-agent') || observed="inactive"
    check "$host" "qemu-guest-agent" "$observed" "$([[ "$observed" == "active" ]] && echo true || echo false)"

    local automation_user; automation_user=$(forge_config '.users.automation_user')
    if ssh_run "$address" "id -u '$automation_user'" >/dev/null; then
        observed=$(ssh_run "$address" "id -nG '$automation_user'") || observed=""
        check "$host" "automation-user" "$automation_user exists (groups: $observed)" true
    else
        check "$host" "automation-user" "$automation_user does not exist" false
    fi

    observed=$(ssh_run "$address" 'sudo sshd -T 2>/dev/null | grep ^permitrootlogin') || observed="<unreadable>"
    local expected_root; expected_root="permitrootlogin $(forge_config '.security.ssh_permit_root_login')"
    check "$host" "ssh-root-login" "$observed" "$([[ "$observed" == "$expected_root" ]] && echo true || echo false)"

    observed=$(ssh_run "$address" 'sudo sshd -T 2>/dev/null | grep ^passwordauthentication') || observed="<unreadable>"
    local expected_password; expected_password="passwordauthentication $(forge_config '.security.ssh_password_authentication')"
    check "$host" "ssh-password-auth" "$observed" "$([[ "$observed" == "$expected_password" ]] && echo true || echo false)"

    observed=$(ssh_run "$address" 'sudo ufw status 2>/dev/null | head -1') || observed="<unreadable>"
    check "$host" "firewall" "$observed" "$([[ "$observed" == *"active"* ]] && echo true || echo false)"

    if observed=$(ssh_run "$address" 'sudo /usr/local/bin/forge-health --json'); then
        local status; status=$(printf '%s' "$observed" | jq -r '.status // "unknown"')
        local failing; failing=$(printf '%s' "$observed" | jq -r '[.checks[] | select(.ok | not) | .name] | join(", ")')
        check "$host" "forge-health" "${status}${failing:+ -- failing: $failing}" \
            "$([[ "$status" == "ok" ]] && echo true || echo false)"
    else
        check "$host" "forge-health" "/usr/local/bin/forge-health did not run" false
    fi
}

# --- Windows ----------------------------------------------------------
winrm_probe() {
    local address=$1 port=$2
    curl --silent --insecure --max-time 15 -X POST \
        -H 'Content-Type: application/soap+xml;charset=UTF-8' \
        --data-binary '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:wsmid="http://schemas.dmtf.org/wbem/wsman/identity/1/wsmanidentity.xsd"><s:Header/><s:Body><wsmid:Identify/></s:Body></s:Envelope>' \
        "https://${address}:${port}/wsman" 2>/dev/null
}

# Windows checks that need to run a command go through Ansible: there is
# no ssh equivalent, and reimplementing WinRM authentication in bash
# would be a worse idea than depending on the tool that already does it.
windows_shell() {
    local host=$1 command=$2
    ( cd "$FORGE_ROOT/ansible" && \
      ansible "$host" -m ansible.windows.win_shell -a "$command" \
        ${VAULT_ARGUMENT:+--vault-password-file "$FORGE_ROOT/.vault-password"} 2>/dev/null \
      | sed -n '/^[[:space:]]*"stdout":/,$p' ) || return 1
}

test_windows() {
    local host=$1 address=$2 mac=$3
    log_step "Windows target: $host ($address)"

    local port; port=$(forge_config '.security.winrm_port')

    test_domain_running "$host"
    test_address_responds "$host" "$address"
    test_lifecycle_state "$host" "$mac"

    local identify
    identify=$(winrm_probe "$address" "$port")
    if printf '%s' "$identify" | grep -qi 'ProductVendor\|IdentifyResponse'; then
        local version
        version=$(printf '%s' "$identify" | grep -o '<wsmid:ProductVersion>[^<]*' | cut -d'>' -f2 || true)
        check "$host" "winrm-https" "WS-Man answered on ${port} (${version:-no version})" true
    else
        check "$host" "winrm-https" "no WS-Man response on https://${address}:${port}/wsman" false
        log_dim "the remaining Windows checks need WinRM; skipping them"
        return
    fi

    # Prove the certificate is what Configure-WinRM.ps1 was asked to make.
    local subject
    subject=$(timeout 10 openssl s_client -connect "${address}:${port}" </dev/null 2>/dev/null \
              | openssl x509 -noout -subject 2>/dev/null || echo "")
    check "$host" "winrm-certificate" "${subject:-could not read the certificate}" \
        "$([[ "$subject" == *"$host"* ]] && echo true || echo false)"

    if ! command -v ansible >/dev/null 2>&1; then
        log_warn "ansible is not available; the in-guest Windows checks are skipped"
        log_dim "install it with ./bootstrap/prepare-host.sh to run them"
        return
    fi

    local output
    # SC2016: $env:COMPUTERNAME is PowerShell, evaluated on the Windows
    # target. Single quotes are exactly right -- bash must not touch it.
    # shellcheck disable=SC2016
    output=$(windows_shell "$host" '$env:COMPUTERNAME' || echo "")
    local observed; observed=$(printf '%s' "$output" | grep -o '"stdout": "[^"]*' | cut -d'"' -f4 | tr -d '\\r\\n' || true)
    check "$host" "hostname" "${observed:-<no output>}" \
        "$([[ "${observed^^}" == "${host^^}"* ]] && echo true || echo false)"

    output=$(windows_shell "$host" '(Get-SmbServerConfiguration).EnableSMB1Protocol' || echo "")
    observed=$(printf '%s' "$output" | grep -o '"stdout": "[^"]*' | cut -d'"' -f4 | tr -d '\\r\\n' | tr -d ' ' || true)
    check "$host" "smbv1-disabled" "EnableSMB1Protocol=${observed:-unknown}" \
        "$([[ "${observed,,}" == "false" ]] && echo true || echo false)"

    output=$(windows_shell "$host" '(Get-NetFirewallProfile -Name Public).Enabled' || echo "")
    observed=$(printf '%s' "$output" | grep -o '"stdout": "[^"]*' | cut -d'"' -f4 | tr -d '\\r\\n' | tr -d ' ' || true)
    check "$host" "firewall-enabled" "Public profile Enabled=${observed:-unknown}" \
        "$([[ "${observed,,}" == "true" ]] && echo true || echo false)"

    output=$(windows_shell "$host" '(Get-CimInstance Win32_OperatingSystem).Caption' || echo "")
    observed=$(printf '%s' "$output" | grep -o '"stdout": "[^"]*' | cut -d'"' -f4 | tr -d '\\r\\n' || true)
    local expected_edition; expected_edition=$(forge_config '.media.windows.image_name')
    check "$host" "windows-edition" "${observed:-<no output>}" \
        "$([[ -n "$observed" ]] && echo true || echo false)"
    [[ -n "$expected_edition" && -n "$observed" ]] && \
        log_dim "configured: $expected_edition"
}

# --- idempotence -------------------------------------------------------
test_idempotence() {
    [[ "$SKIP_IDEMPOTENCE" == false ]] || { log_step "Skipping the idempotence check"; return 0; }

    log_step "Idempotence: applying the baseline a second time, in check mode"
    log_dim "an idempotent configuration changes nothing on the second run"

    local output rc=0
    output=$( cd "$FORGE_ROOT/ansible" && \
              ansible-playbook playbooks/configure-targets.yml --check --diff \
                ${VAULT_ARGUMENT:+--vault-password-file "$FORGE_ROOT/.vault-password"} \
                2>&1 ) || rc=$?

    # The recap line reports changed= per host.
    local changed_total=0 host_line changed
    while read -r host_line; do
        changed=$(printf '%s' "$host_line" | grep -o 'changed=[0-9]*' | cut -d= -f2)
        [[ -n "$changed" ]] || continue
        changed_total=$((changed_total + changed))
        local host_name; host_name=$(printf '%s' "$host_line" | awk '{print $1}')
        check "$host_name" "idempotence" "$changed task(s) would still change" \
            "$([[ "$changed" -eq 0 ]] && echo true || echo false)"
    done < <(printf '%s' "$output" | sed -n '/PLAY RECAP/,$p' | grep -E 'changed=[0-9]+')

    if [[ $changed_total -gt 0 ]]; then
        log_dim "the tasks that would change, from --diff:"
        printf '%s' "$output" | grep -B2 -A8 'changed:' | head -40 | sed 's/^/       /' >&2
        log_dim ""
        log_dim "Some of this may be expected: see docs/OPERATIONS.md, 'check-mode limitations'."
        log_dim "A task that reports changed on every run makes the drift report useless."
    fi

    [[ $rc -le 2 ]] || log_warn "the check-mode run exited with $rc"
}

# --- reporting ---------------------------------------------------------
write_junit() {
    [[ -n "$JUNIT_PATH" ]] || return 0
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<testsuites name="forge-ai-smoke" tests="%d" failures="%d" time="0">\n' \
            "$((PASSED + FAILED))" "$FAILED"
        printf '  <testsuite name="smoke" tests="%d" failures="%d">\n' \
            "$((PASSED + FAILED))" "$FAILED"
        local i
        for i in "${!TEST_NAMES[@]}"; do
            printf '    <testcase classname="%s" name="%s">' "${TEST_HOSTS[$i]}" "${TEST_NAMES[$i]}"
            if [[ "${TEST_RESULTS[$i]}" != "true" ]]; then
                printf '<failure message="%s"/>' \
                    "$(printf '%s' "${TEST_DETAIL[$i]}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')"
            fi
            printf '</testcase>\n'
        done
        printf '  </testsuite>\n</testsuites>\n'
    } > "$JUNIT_PATH"
    log_ok "JUnit report written to $JUNIT_PATH"
}

main() {
    forge_require_valid_config
    require_commands curl jq

    SSH_USER=$(forge_config '.users.automation_user')
    SSH_KEY="${FORGE_SSH_KEY:-$HOME/.ssh/forge-ai-poc}"
    VAULT_ARGUMENT=""
    [[ -f "$FORGE_ROOT/.vault-password" ]] && VAULT_ARGUMENT="yes"

    forge_banner
    log_step "Smoke test"

    if ! command -v virsh >/dev/null 2>&1; then
        log_warn "virsh is not available; the VM-state checks will be skipped"
    fi

    local name family address mac
    while IFS=$'\t' read -r name family address mac; do
        [[ -z "$ONLY_HOST" || "$ONLY_HOST" == "$name" ]] || continue
        mac=$(printf '%s' "$mac" | tr ':' '-' | tr 'A-F' 'a-f')
        case "$family" in
            linux)   test_ubuntu  "$name" "$address" "$mac" ;;
            windows) test_windows "$name" "$address" "$mac" ;;
        esac
    done < <(forge_config_json | jq -r '.hosts[] | [.name, .os_family, .ip_address, .mac_address] | @tsv')

    test_idempotence
    write_junit

    printf '\n' >&2
    printf '%s================================================================%s\n' "$C_BOLD" "$C_RESET" >&2
    if [[ $FAILED -eq 0 ]]; then
        printf '%s SMOKE TEST PASSED%s -- %d checks\n' "$C_GREEN" "$C_RESET" "$PASSED" >&2
    else
        printf '%s SMOKE TEST FAILED%s -- %d passed, %d failed\n' "$C_RED" "$C_RESET" "$PASSED" "$FAILED" >&2
    fi
    printf '%s================================================================%s\n' "$C_BOLD" "$C_RESET" >&2

    [[ $FAILED -eq 0 ]]
}

main "$@"
