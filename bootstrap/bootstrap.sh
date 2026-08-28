#!/usr/bin/env bash
# =====================================================================
# FORGE-AI :: bootstrap the control plane
# =====================================================================
#   ./bootstrap/bootstrap.sh
#   ./bootstrap/bootstrap.sh --skip-checks
#   ./bootstrap/bootstrap.sh --resume-from control-plane
#
# Idempotent from end to end: every stage checks whether its work is
# already done before doing it, and nothing overwrites an operator's
# configuration without saying so.
#
# The stage order is a hard dependency chain, not a preference:
#
#   secrets  -> the compose stack refuses to start without them
#   network  -> the bridge must exist before Docker can bind 192.168.250.1
#   compose  -> Gitea and Semaphore must be up before they can be configured
#   gitops   -> tokens can only be issued by a running service
# =====================================================================
set -Eeuo pipefail

export FORGE_SCRIPT_NAME="bootstrap.sh"
# shellcheck source=bootstrap/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
forge_enable_traps

SKIP_CHECKS=false
RESUME_FROM=""
ANSIBLE_EXTRA_ARGS=()

readonly -a STAGES=(config secrets prereq network control-plane gitops verify)

usage() {
    cat <<'USAGE'
Usage: ./bootstrap/bootstrap.sh [OPTIONS]

Brings up the FORGE-AI control plane: secrets, the provisioning network,
the Docker stack, and the Gitea/Semaphore configuration.

Options:
  --skip-checks          skip the prerequisite validation (not advised)
  --resume-from STAGE    start at STAGE, skipping earlier ones
  -e KEY=VALUE           pass an extra variable to Ansible (repeatable)
  -h, --help             this message

Stages, in dependency order:
  config          ensure config/poc.yml exists and validates
  secrets         generate compose/.env, the vault, the SSH key, TLS
  prereq          validate the host can run the PoC
  network         create the isolated libvirt provisioning network
  control-plane   start Gitea, Semaphore, PostgreSQL, the boot server
  gitops          configure the Gitea repository and Semaphore project
  verify          confirm every endpoint answers

The order is a dependency chain, not a preference: the compose stack
binds to the bridge address, so the network must exist first.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-checks)  SKIP_CHECKS=true; shift ;;
        --resume-from)  RESUME_FROM="${2:?--resume-from needs a stage name}"; shift 2 ;;
        -e)             ANSIBLE_EXTRA_ARGS+=(-e "${2:?-e needs KEY=VALUE}"); shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)              log_err "unknown option: $1"; usage; exit 2 ;;
    esac
done

if [[ -n "$RESUME_FROM" ]]; then
    # shellcheck disable=SC2076   # literal match is what is wanted here
    if [[ ! " ${STAGES[*]} " =~ " ${RESUME_FROM} " ]]; then
        die "unknown stage '$RESUME_FROM'; valid stages: ${STAGES[*]}"
    fi
fi

STAGE_REACHED=false
should_run() {
    local stage=$1
    [[ -z "$RESUME_FROM" ]] && return 0
    [[ "$stage" == "$RESUME_FROM" ]] && STAGE_REACHED=true
    [[ "$STAGE_REACHED" == true ]]
}

ansible_playbook() {
    local playbook=$1; shift
    local -a command=("$FORGE_ANSIBLE_PLAYBOOK" "playbooks/$playbook")

    if [[ -f "$FORGE_ROOT/.vault-password" ]]; then
        command+=(--vault-password-file "$FORGE_ROOT/.vault-password")
    fi
    command+=("${ANSIBLE_EXTRA_ARGS[@]}" "$@")

    log "running: ${command[*]}"
    ( cd "$FORGE_ROOT/ansible" && "${command[@]}" )
}

# ---------------------------------------------------------------------
# Stage: config
# ---------------------------------------------------------------------
stage_config() {
    should_run config || { log_dim "skipping stage: config"; return 0; }
    log_step "Stage 1/7: configuration"

    if [[ ! -f "$FORGE_ROOT/config/poc.yml" ]]; then
        log "config/poc.yml does not exist; creating it from the example"
        cp "$FORGE_ROOT/config/poc.example.yml" "$FORGE_ROOT/config/poc.yml"
        log_ok "created config/poc.yml"
        log_warn "review it before deploying -- especially the network and the Windows ISO path"
    else
        log_ok "config/poc.yml exists"
    fi

    log "validating"
    if ! "$FORGE_ROOT/scripts/validate-config.py"; then
        die "config/poc.yml does not validate; fix the findings above and re-run"
    fi
    log_ok "configuration is valid"
}

# ---------------------------------------------------------------------
# Stage: secrets
# ---------------------------------------------------------------------
stage_secrets() {
    should_run secrets || { log_dim "skipping stage: secrets"; return 0; }
    log_step "Stage 2/7: secrets"

    # create-secrets.sh is itself idempotent and never overwrites an
    # existing value without --force, so it is safe to call every time.
    "$FORGE_ROOT/bootstrap/create-secrets.sh"
}

# ---------------------------------------------------------------------
# Stage: prerequisites
# ---------------------------------------------------------------------
stage_prereq() {
    should_run prereq || { log_dim "skipping stage: prereq"; return 0; }
    if [[ "$SKIP_CHECKS" == true ]]; then
        log_step "Stage 3/7: prerequisites (SKIPPED)"
        log_warn "--skip-checks was passed; failures will surface later and less helpfully"
        return 0
    fi
    log_step "Stage 3/7: prerequisites"

    if ! "$FORGE_ROOT/bootstrap/check-prerequisites.sh"; then
        log_err "the host is not ready"
        log_dim "install what is missing with ./bootstrap/prepare-host.sh"
        log_dim "or re-run with --skip-checks if you are certain"
        die "prerequisites not met"
    fi
}

# ---------------------------------------------------------------------
# Stage: network
# ---------------------------------------------------------------------
stage_network() {
    should_run network || { log_dim "skipping stage: network"; return 0; }
    log_step "Stage 4/7: provisioning network"

    local bridge; bridge=$(forge_config '.provisioning_network.bridge')
    local gateway; gateway=$(forge_config '.provisioning_network.gateway')

    if [[ -d "/sys/class/net/$bridge" ]]; then
        log_ok "bridge $bridge already exists"
    else
        log "creating the libvirt network and bridge $bridge"
    fi

    ansible_playbook create-provisioning-network.yml

    # The compose stack binds to this address; if it is not up, Docker
    # fails with "cannot assign requested address", which is a much less
    # useful message than this one.
    local waited=0
    until ip -4 addr show dev "$bridge" 2>/dev/null | grep -q "$gateway"; do
        (( waited >= 30 )) && die "bridge $bridge did not acquire $gateway within 30s"
        sleep 2; waited=$((waited + 2))
    done
    log_ok "$bridge is up with $gateway"
}

# ---------------------------------------------------------------------
# Stage: control plane
# ---------------------------------------------------------------------
stage_control_plane() {
    should_run control-plane || { log_dim "skipping stage: control-plane"; return 0; }
    log_step "Stage 5/7: control plane"

    ansible_playbook bootstrap-control-plane.yml --tags bootstrap --skip-tags gitops
}

# ---------------------------------------------------------------------
# Stage: GitOps
# ---------------------------------------------------------------------
create_gitea_token() {
    local admin_user; admin_user=$(sed -n 's/^GITEA_ADMIN_USER=//p' "$FORGE_ROOT/compose/.env" | head -1)
    local token_name="forge-ai-automation"

    # Gitea's CLI can mint a scoped token without an interactive login,
    # which avoids putting the admin password on a command line.
    local output
    if output=$(docker exec -u git forge-gitea gitea admin user generate-access-token \
                    --username "$admin_user" \
                    --token-name "$token_name" \
                    --scopes "write:organization,write:repository,write:user" 2>&1); then
        printf '%s' "$output" | sed -n 's/.*Access token was successfully created: //p' | tr -d '\r\n'
        return 0
    fi

    if printf '%s' "$output" | grep -q "already exists"; then
        log_warn "a Gitea token named '$token_name' already exists" >&2
        log_dim "Gitea cannot re-read an existing token's value -- it is only shown once." >&2
        log_dim "Either reuse the value already in the vault, or delete the token in the UI" >&2
        log_dim "(Settings -> Applications) and re-run this stage." >&2
        return 1
    fi

    log_err "could not create a Gitea token: $output" >&2
    return 1
}

create_semaphore_token() {
    local api resolve admin_user admin_password jar
    # Same proxy topology as stage_gitops's readiness checks -- Semaphore's
    # raw port is not published on the host, only the TLS proxy is.
    local https_port; https_port=$(forge_config '.control_plane.proxy_https_port')
    local semaphore_host; semaphore_host=$(forge_config '.control_plane.semaphore_hostname')
    api="https://${semaphore_host}:${https_port}/api"
    resolve="${semaphore_host}:${https_port}:127.0.0.1"
    admin_user=$(sed -n 's/^SEMAPHORE_ADMIN_USER=//p' "$FORGE_ROOT/compose/.env" | head -1)
    admin_password=$(sed -n 's/^SEMAPHORE_ADMIN_PASSWORD=//p' "$FORGE_ROOT/compose/.env" | head -1)
    jar=$(mktemp); chmod 0600 "$jar"

    # The password goes in a request body, never on a command line where
    # it would be visible in the process table.
    if ! curl -fsSk --resolve "$resolve" -X POST "$api/auth/login" \
            -H 'Content-Type: application/json' \
            -c "$jar" \
            --data-binary @<(printf '{"auth":"%s","password":"%s"}' "$admin_user" "$admin_password") \
            >/dev/null 2>&1; then
        rm -f "$jar"
        log_err "could not log in to Semaphore as $admin_user" >&2
        return 1
    fi

    local token
    token=$(curl -fsSk --resolve "$resolve" -X POST "$api/user/tokens" -b "$jar" 2>/dev/null | jq -r '.id // empty')
    rm -f "$jar"

    [[ -n "$token" ]] || { log_err "Semaphore did not return a token" >&2; return 1; }
    printf '%s' "$token"
}

vault_set() {
    local key=$1 value=$2
    local vault="$FORGE_ROOT/ansible/inventories/poc/group_vars/all/vault.yml"
    local plain; plain=$(mktemp); chmod 0600 "$plain"
    # shellcheck disable=SC2064
    trap "rm -f '$plain'" RETURN

    ansible-vault view --vault-password-file "$FORGE_ROOT/.vault-password" "$vault" > "$plain"
    python3 - "$plain" "$key" "$value" <<'PY'
import sys, pathlib
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
lines = p.read_text().splitlines(keepends=True)
found = False
out = []
for line in lines:
    if line.startswith(f"{key}:"):
        out.append(f'{key}: "{value}"\n'); found = True
    else:
        out.append(line)
if not found:
    out.append(f'{key}: "{value}"\n')
p.write_text("".join(out))
PY
    ansible-vault encrypt --vault-password-file "$FORGE_ROOT/.vault-password" \
        --output "$vault" "$plain" >/dev/null
    chmod 0600 "$vault"
}

stage_gitops() {
    should_run gitops || { log_dim "skipping stage: gitops"; return 0; }
    log_step "Stage 6/7: Gitea and Semaphore"

    # Neither service publishes its raw HTTP port on the host -- only
    # the nginx proxy's TLS port is (compose/nginx/proxy.conf routes by
    # SNI/Host header to gitea:3000 or semaphore:3000 inside the Docker
    # network). --resolve fakes the DNS lookup so this works before
    # /etc/hosts has the *.poc.local entries the final summary tells the
    # operator to add on their own machine.
    local https_port; https_port=$(forge_config '.control_plane.proxy_https_port')
    local gitea_host; gitea_host=$(forge_config '.control_plane.gitea_hostname')
    local semaphore_host; semaphore_host=$(forge_config '.control_plane.semaphore_hostname')

    log "waiting for Gitea"
    local waited=0
    # /api/v1/version requires a signed-in user on this Gitea version
    # ("Only signed in user is allowed to call APIs", 403) -- /api/healthz
    # is the unauthenticated readiness endpoint.
    until curl -fsSk --resolve "${gitea_host}:${https_port}:127.0.0.1" \
            "https://${gitea_host}:${https_port}/api/healthz" >/dev/null 2>&1; do
        (( waited >= 180 )) && die "Gitea did not become ready within 180s (docker compose logs gitea)"
        sleep 5; waited=$((waited + 5))
    done
    log_ok "Gitea is answering"

    log "waiting for Semaphore"
    waited=0
    until curl -fsSk --resolve "${semaphore_host}:${https_port}:127.0.0.1" \
            "https://${semaphore_host}:${https_port}/api/ping" >/dev/null 2>&1; do
        (( waited >= 180 )) && die "Semaphore did not become ready within 180s (docker compose logs semaphore)"
        sleep 5; waited=$((waited + 5))
    done
    log_ok "Semaphore is answering"

    # Tokens can only be minted by a running service, which is why this
    # happens here rather than in create-secrets.sh.
    local existing_gitea_token
    existing_gitea_token=$(ansible-vault view --vault-password-file "$FORGE_ROOT/.vault-password" \
        "$FORGE_ROOT/ansible/inventories/poc/group_vars/all/vault.yml" 2>/dev/null \
        | sed -n 's/^vault_gitea_api_token: *"\(.*\)"/\1/p')

    if [[ -z "$existing_gitea_token" ]]; then
        log "creating a Gitea API token"
        local gitea_token
        if gitea_token=$(create_gitea_token); then
            vault_set vault_gitea_api_token "$gitea_token"
            log_ok "Gitea token stored in the vault"
        else
            log_warn "continuing without a Gitea token; the gitops role will stop and tell you what to do"
        fi
    else
        log_ok "a Gitea token is already in the vault"
    fi

    local existing_semaphore_token
    existing_semaphore_token=$(ansible-vault view --vault-password-file "$FORGE_ROOT/.vault-password" \
        "$FORGE_ROOT/ansible/inventories/poc/group_vars/all/vault.yml" 2>/dev/null \
        | sed -n 's/^vault_semaphore_api_token: *"\(.*\)"/\1/p')

    if [[ -z "$existing_semaphore_token" ]]; then
        log "creating a Semaphore API token"
        local semaphore_token
        if semaphore_token=$(create_semaphore_token); then
            vault_set vault_semaphore_api_token "$semaphore_token"
            env_write SEMAPHORE_API_TOKEN "$semaphore_token"
            log_ok "Semaphore token stored in the vault and in compose/.env"
        else
            log_warn "continuing without a Semaphore token; the semaphore_config role will explain how to create one"
        fi
    else
        log_ok "a Semaphore token is already in the vault"
    fi

    ansible_playbook bootstrap-control-plane.yml --tags gitops
}

env_write() {
    local key=$1 value=$2
    python3 - "$FORGE_ROOT/compose/.env" "$key" "$value" <<'PY'
import sys, pathlib
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
lines = p.read_text().splitlines(keepends=True)
out, found = [], False
for line in lines:
    if line.startswith(f"{key}="):
        out.append(f"{key}={value}\n"); found = True
    else:
        out.append(line)
if not found:
    out.append(f"{key}={value}\n")
p.write_text("".join(out))
PY
    chmod 0600 "$FORGE_ROOT/compose/.env"
}

# ---------------------------------------------------------------------
# Stage: verify
# ---------------------------------------------------------------------
stage_verify() {
    should_run verify || { log_dim "skipping stage: verify"; return 0; }
    log_step "Stage 7/7: verification"

    local gateway boot_port
    gateway=$(forge_config '.provisioning_network.gateway')
    boot_port=$(forge_config '.control_plane.boot_http_port')

    local -a endpoints=(
        "http://${gateway}:${boot_port}/healthz|boot artefact server"
        "http://${gateway}:${boot_port}/api/healthz|provisioning state service"
        "http://127.0.0.1:$(forge_config '.control_plane.gitea_http_port')/api/v1/version|Gitea"
        "http://127.0.0.1:$(forge_config '.control_plane.semaphore_http_port')/api/ping|Semaphore"
    )

    local failures=0 entry url label
    for entry in "${endpoints[@]}"; do
        url="${entry%%|*}"; label="${entry##*|}"
        if curl -fsS --max-time 10 "$url" >/dev/null 2>&1; then
            log_ok "$label"
        else
            log_err "$label is not answering at $url"
            failures=$((failures + 1))
        fi
    done

    [[ $failures -eq 0 ]] || die "$failures endpoint(s) are not answering; see 'docker compose ps' and 'docker compose logs'"
}

summary() {
    local gateway boot_port https_port
    gateway=$(forge_config '.provisioning_network.gateway')
    boot_port=$(forge_config '.control_plane.boot_http_port')
    https_port=$(forge_config '.control_plane.proxy_https_port')

    log_step "Control plane is up"
    cat >&2 <<SUMMARY

  Gitea       https://$(forge_config '.control_plane.gitea_hostname'):${https_port}
  Semaphore   https://$(forge_config '.control_plane.semaphore_hostname'):${https_port}
  Boot server http://${gateway}:${boot_port}
  State API   http://${gateway}:${boot_port}/api/state

  Both UIs use a self-signed certificate and are published on the
  loopback address. From another machine:
    ssh -L ${https_port}:127.0.0.1:${https_port} $(id -un)@$(hostname)
  and add to your /etc/hosts:
    127.0.0.1  $(forge_config '.control_plane.gitea_hostname') $(forge_config '.control_plane.semaphore_hostname')

  Next:
    make prepare-media     download and unpack the installation media
    make provision         create the VMs and install both operating systems
    make validate          smoke tests, idempotence check, deployment report

  Or run the whole lifecycle:
    make deploy

SUMMARY
}

main() {
    forge_banner
    log "repository: $FORGE_ROOT"
    [[ -n "$RESUME_FROM" ]] && log_warn "resuming from stage: $RESUME_FROM"

    require_commands curl jq python3 git

    stage_config
    stage_secrets
    stage_prereq
    stage_network
    stage_control_plane
    stage_gitops
    stage_verify
    summary
}

main "$@"
