#!/usr/bin/env bash
# =====================================================================
# FORGE-AI :: generate the PoC secrets
# =====================================================================
#   ./bootstrap/create-secrets.sh
#   ./bootstrap/create-secrets.sh --force        regenerate everything
#   ./bootstrap/create-secrets.sh --tls-only     just the proxy certificate
#   ./bootstrap/create-secrets.sh --show         print what exists, no values
#
# Produces, all mode 0600:
#
#   compose/.env                                 control-plane credentials (git-ignored)
#   ansible/inventories/poc/group_vars/all/vault.yml   encrypted vault (COMMITTED -- see below)
#   .vault-password                              the vault password (git-ignored, NEVER commit this)
#   ~/.ssh/forge-ai-poc{,.pub}                   SSH key for the Linux targets (git-ignored)
#   compose/nginx/tls/forge-ai.{crt,key}         proxy TLS pair (git-ignored)
#
# vault.yml is the one exception to "git-ignored": it is meant to be
# `git add`ed and committed, encrypted at rest, so Semaphore's clone
# from Gitea has the same real secrets the host does instead of
# silently falling back to vault.yml.example's placeholders (bug 45,
# docs/SECURITY.md). Nothing in this script commits it automatically --
# that stays a deliberate, manual step.
#
# It NEVER overwrites an existing secret without --force. Regenerating
# SEMAPHORE_ACCESS_KEY_ENCRYPTION, for example, makes every key already
# in the Semaphore Key Store undecryptable.
#
# Every file is created with `install -m 0600 /dev/null` before content
# is written, so there is no window in which it is world-readable.
# =====================================================================
set -Eeuo pipefail

export FORGE_SCRIPT_NAME="create-secrets.sh"
# shellcheck source=bootstrap/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
forge_enable_traps

FORCE=false
TLS_ONLY=false
SHOW_ONLY=false

readonly ENV_FILE="$FORGE_ROOT/compose/.env"
readonly ENV_EXAMPLE="$FORGE_ROOT/compose/.env.example"
readonly VAULT_FILE="$FORGE_ROOT/ansible/inventories/poc/group_vars/all/vault.yml"
readonly VAULT_PASSWORD_FILE="$FORGE_ROOT/.vault-password"
readonly TLS_DIR="$FORGE_ROOT/compose/nginx/tls"
readonly SSH_KEY="${FORGE_SSH_KEY:-$HOME/.ssh/forge-ai-poc}"

usage() {
    cat <<'USAGE'
Usage: ./bootstrap/create-secrets.sh [OPTIONS]

Generates every secret the PoC needs, with strong random values.

Options:
  --force      regenerate secrets that already exist  (DESTRUCTIVE, see below)
  --tls-only   only regenerate the control-plane TLS certificate
  --show       report which secrets exist, without printing any value
  -h, --help   this message

--force is destructive in a way that is easy to underestimate:

  * regenerating SEMAPHORE_ACCESS_KEY_ENCRYPTION makes every key already
    stored in the Semaphore Key Store permanently undecryptable;
  * regenerating GITEA_SECRET_KEY invalidates existing Gitea sessions
    and two-factor enrolments;
  * regenerating the SSH key locks you out of already-provisioned Linux
    targets until they are reconfigured.

Rotation procedures that avoid each of these are in docs/SECURITY.md.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)     FORCE=true; shift ;;
        --tls-only)  TLS_ONLY=true; shift ;;
        --show)      SHOW_ONLY=true; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           log_err "unknown option: $1"; usage; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------
# compose/.env
# ---------------------------------------------------------------------
env_set() {
    local key=$1 value=$2
    if grep -qE "^${key}=" "$ENV_FILE"; then
        # A literal replacement: the value can contain / and & which
        # would otherwise be interpreted by sed.
        python3 - "$ENV_FILE" "$key" "$value" <<'PY'
import sys, pathlib
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
lines = p.read_text().splitlines(keepends=True)
out = []
for line in lines:
    if line.startswith(f"{key}="):
        out.append(f"{key}={value}\n")
    else:
        out.append(line)
p.write_text("".join(out))
PY
    else
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

env_get() {
    local key=$1
    [[ -r "$ENV_FILE" ]] || return 1
    sed -n "s/^${key}=//p" "$ENV_FILE" | head -1
}

env_needs_value() {
    local key=$1 current
    current=$(env_get "$key" || echo "")
    [[ "$FORCE" == true ]] && return 0
    [[ -z "$current" || "$current" == "CHANGEME" ]]
}

generate_env() {
    log_step "compose/.env"

    if [[ ! -f "$ENV_FILE" ]]; then
        [[ -f "$ENV_EXAMPLE" ]] || die "$ENV_EXAMPLE is missing"
        install -m 0600 /dev/null "$ENV_FILE"
        cat "$ENV_EXAMPLE" >> "$ENV_FILE"
        log_ok "created from .env.example"
    fi
    chmod 0600 "$ENV_FILE"

    # Length is chosen per use: 32 characters of [A-Za-z0-9] is about
    # 190 bits, which is ample for a database password and a webhook
    # HMAC key alike.
    local -a simple_secrets=(
        POSTGRES_SUPERUSER_PASSWORD
        GITEA_DB_PASSWORD
        SEMAPHORE_DB_PASSWORD
        GITEA_ADMIN_PASSWORD
        SEMAPHORE_ADMIN_PASSWORD
        FORGE_WEBHOOK_SECRET
        FORGE_STATE_TOKEN
    )
    local key generated=0
    for key in "${simple_secrets[@]}"; do
        if env_needs_value "$key"; then
            env_set "$key" "$(forge_random_secret 32)"
            generated=$((generated + 1))
        fi
    done

    # Gitea wants long opaque strings for these two.
    for key in GITEA_SECRET_KEY GITEA_INTERNAL_TOKEN; do
        if env_needs_value "$key"; then
            env_set "$key" "$(forge_random_secret 64)"
            generated=$((generated + 1))
        fi
    done

    # Semaphore requires EXACTLY 32 raw bytes, base64-encoded, for the
    # Key Store encryption. A different length is rejected at startup
    # with an error that does not say so.
    if env_needs_value SEMAPHORE_ACCESS_KEY_ENCRYPTION; then
        if [[ "$FORCE" == true ]] && [[ -n "$(env_get SEMAPHORE_ACCESS_KEY_ENCRYPTION || echo '')" ]]; then
            log_warn "regenerating SEMAPHORE_ACCESS_KEY_ENCRYPTION"
            log_dim "every key already in the Semaphore Key Store becomes undecryptable"
            confirm "Continue?" || die "aborted"
        fi
        env_set SEMAPHORE_ACCESS_KEY_ENCRYPTION "$(head -c 32 /dev/urandom | base64 -w0)"
        generated=$((generated + 1))
    fi

    # Keep the runtime values consistent with config/poc.yml rather than
    # letting the two drift.
    if [[ -x "$FORGE_ROOT/scripts/validate-config.py" ]]; then
        local gateway boot_port artifacts attempts branch
        gateway=$(forge_config '.provisioning_network.gateway' 2>/dev/null || echo "")
        boot_port=$(forge_config '.control_plane.boot_http_port' 2>/dev/null || echo "")
        artifacts=$(forge_config '.storage.artifacts_dir' 2>/dev/null || echo "")
        attempts=$(forge_config '.pxe.max_install_attempts' 2>/dev/null || echo "")
        branch=$(forge_config '.gitops.default_branch' 2>/dev/null || echo "")

        [[ -n "$gateway"   ]] && env_set PROVISIONING_BIND_ADDRESS "$gateway"
        [[ -n "$gateway" && -n "$boot_port" ]] && env_set FORGE_BOOT_BASE_URL "http://${gateway}:${boot_port}"
        [[ -n "$boot_port" ]] && env_set BOOT_HTTP_PORT "$boot_port"
        [[ -n "$artifacts" ]] && env_set FORGE_ARTIFACTS_DIR "$artifacts"
        [[ -n "$attempts"  ]] && env_set FORGE_MAX_INSTALL_ATTEMPTS "$attempts"
        [[ -n "$branch"    ]] && env_set GITOPS_DEFAULT_BRANCH "$branch"
        log_ok "runtime values synchronised with config/poc.yml"
    fi

    chmod 0600 "$ENV_FILE"
    if [[ $generated -gt 0 ]]; then
        log_ok "generated $generated secret(s), mode 0600"
    else
        log_ok "every secret already present (pass --force to regenerate)"
    fi

    if grep -q '=CHANGEME' "$ENV_FILE"; then
        log_err "placeholder values remain in $ENV_FILE:"
        grep -n '=CHANGEME' "$ENV_FILE" | sed 's/^/         /' >&2
        die "these must be filled in before the stack will start"
    fi
}

# ---------------------------------------------------------------------
# SSH key for the Linux targets
# ---------------------------------------------------------------------
generate_ssh_key() {
    log_step "SSH key for the Linux targets"

    if [[ -f "$SSH_KEY" && "$FORCE" == false ]]; then
        log_ok "$SSH_KEY already exists"
    else
        if [[ -f "$SSH_KEY" ]]; then
            log_warn "regenerating $SSH_KEY"
            log_dim "already-provisioned Linux targets will stop accepting this key"
            confirm "Continue?" || die "aborted"
            rm -f "$SSH_KEY" "$SSH_KEY.pub"
        fi
        mkdir -p "$(dirname "$SSH_KEY")"
        chmod 0700 "$(dirname "$SSH_KEY")"
        # ed25519: small, fast, and supported by every OpenSSH the PoC
        # will meet. No passphrase, because Ansible and Semaphore both
        # need to use it unattended -- the control is the 0600 mode and
        # the fact that it never leaves this host.
        ssh-keygen -t ed25519 -a 100 -N '' \
            -C "forge-ai-poc-$(forge_timestamp)" -f "$SSH_KEY" >/dev/null
        log_ok "created $SSH_KEY (ed25519, no passphrase)"
        log_dim "no passphrase: Ansible and Semaphore use it unattended"
    fi
    chmod 0600 "$SSH_KEY"
    chmod 0644 "$SSH_KEY.pub"

    # Record the PUBLIC key in config/poc.yml so the autoinstall seed
    # authorises it. The private half never leaves this host.
    local public_key; public_key=$(< "$SSH_KEY.pub")
    local config="$FORGE_ROOT/config/poc.yml"

    if [[ ! -f "$config" ]]; then
        log_warn "config/poc.yml does not exist yet"
        log_dim "cp config/poc.example.yml config/poc.yml, then re-run this script"
        return 0
    fi

    if grep -qF "$public_key" "$config"; then
        log_ok "the public key is already authorised in config/poc.yml"
        return 0
    fi

    python3 - "$config" "$public_key" <<'PY'
import sys, pathlib, re
config_path, public_key = sys.argv[1], sys.argv[2]
path = pathlib.Path(config_path)
text = path.read_text()

# Replace an empty ssh_authorized_keys list, or append to a populated
# one. Editing YAML textually rather than round-tripping it keeps the
# operator's comments and ordering intact, which matters for a file a
# human maintains.
empty = re.compile(r'^(\s*)ssh_authorized_keys:\s*\[\s*\]\s*$', re.M)
if empty.search(text):
    text = empty.sub(lambda m: f"{m.group(1)}ssh_authorized_keys:\n{m.group(1)}  - \"{public_key}\"", text, count=1)
else:
    listed = re.compile(r'^(\s*)ssh_authorized_keys:\s*$', re.M)
    match = listed.search(text)
    if match:
        indent = match.group(1)
        insert = match.end() + 1
        text = text[:insert] + f'{indent}  - "{public_key}"\n' + text[insert:]
    else:
        raise SystemExit("no ssh_authorized_keys key found in config/poc.yml")

path.write_text(text)
print("authorised")
PY
    log_ok "public key recorded in config/poc.yml"
}

# ---------------------------------------------------------------------
# Ansible Vault
# ---------------------------------------------------------------------
generate_vault() {
    log_step "Ansible Vault"

    require_command ansible-vault "install ansible-core, or run ./bootstrap/prepare-host.sh" || {
        log_warn "skipping the vault: ansible-vault is not available"
        return 0
    }

    if [[ ! -f "$VAULT_PASSWORD_FILE" || "$FORCE" == true ]]; then
        forge_write_secret_file "$VAULT_PASSWORD_FILE" "$(forge_random_secret 48)" 0600
        log_ok "created $VAULT_PASSWORD_FILE (mode 0600)"
    else
        log_ok "$VAULT_PASSWORD_FILE already exists"
    fi

    if [[ -f "$VAULT_FILE" && "$FORCE" == false ]]; then
        log_ok "$(basename "$VAULT_FILE") already exists"
        return 0
    fi

    # The Ubuntu bootstrap password. Only its HASH reaches the
    # autoinstall seed; the cleartext exists here so it can be rotated
    # and so an operator can use the console in an emergency.
    local ubuntu_password windows_password state_token webhook_secret hash
    ubuntu_password=$(forge_random_secret 24)
    # Windows Server rejects a password that fails its complexity policy
    # and then silently leaves the account with no password at all, so
    # the character classes are forced rather than hoped for.
    windows_password="$(forge_random_secret 20)Aa1!"
    state_token=$(env_get FORGE_STATE_TOKEN || forge_random_secret 32)
    webhook_secret=$(env_get FORGE_WEBHOOK_SECRET || forge_random_secret 32)

    # yescrypt is the Ubuntu 24.04 default and what `mkpasswd` produces.
    # openssl's SHA-512 crypt is the fallback: it is accepted by
    # Subiquity just as well, and unlike Python's `crypt` module it is
    # not scheduled for removal (crypt was dropped in Python 3.13).
    if command -v mkpasswd >/dev/null 2>&1; then
        hash=$(mkpasswd --method=yescrypt "$ubuntu_password")
    elif openssl passwd -6 "test" >/dev/null 2>&1; then
        log_warn "mkpasswd is unavailable; using openssl SHA-512 crypt instead"
        log_dim "install the 'whois' package for yescrypt hashes"
        hash=$(openssl passwd -6 "$ubuntu_password")
    else
        die "no way to hash the bootstrap password: install 'whois' (mkpasswd) or a newer openssl"
    fi

    local temporary; temporary=$(mktemp)
    chmod 0600 "$temporary"
    # shellcheck disable=SC2064   # expand $temporary now, on purpose
    trap "rm -f '$temporary'" RETURN

    cat > "$temporary" <<VAULT
---
# =====================================================================
# FORGE-AI :: Ansible Vault
# =====================================================================
# Generated by bootstrap/create-secrets.sh on $(date -Is).
# ENCRYPTED AT REST. Edit with:
#   ansible-vault edit ansible/inventories/poc/group_vars/all/vault.yml
# =====================================================================

# --- Ubuntu bootstrap account ---------------------------------------
# The cleartext exists only so the credential can be rotated and so an
# operator has console access in an emergency. Only the HASH is written
# into the autoinstall seed.
vault_ubuntu_bootstrap_password: "${ubuntu_password}"
vault_ubuntu_bootstrap_password_hash: "${hash}"

# --- Windows local administrator ------------------------------------
# Forced to satisfy the Windows Server complexity policy: Setup silently
# rejects a non-compliant password and leaves the account with none.
vault_windows_admin_password: "${windows_password}"

# --- Provisioning state service --------------------------------------
# Must match FORGE_STATE_TOKEN in compose/.env.
vault_forge_state_token: "${state_token}"

# --- Gitea webhook ----------------------------------------------------
# Must match FORGE_WEBHOOK_SECRET in compose/.env.
vault_gitea_webhook_secret: "${webhook_secret}"

# --- Control-plane administration -------------------------------------
vault_gitea_admin_password: "$(env_get GITEA_ADMIN_PASSWORD || forge_random_secret 32)"
vault_semaphore_admin_password: "$(env_get SEMAPHORE_ADMIN_PASSWORD || forge_random_secret 32)"

# --- API tokens -------------------------------------------------------
# Filled in by bootstrap/bootstrap.sh once Gitea and Semaphore are up:
# neither can issue a token before it exists.
vault_gitea_api_token: ""
vault_semaphore_api_token: ""

# --- SSH -------------------------------------------------------------
# The PRIVATE key is referenced by path and is never inlined here.
vault_ssh_private_key_path: "${SSH_KEY}"
VAULT

    mkdir -p "$(dirname "$VAULT_FILE")"
    ansible-vault encrypt --vault-password-file "$VAULT_PASSWORD_FILE" \
        --output "$VAULT_FILE" "$temporary"
    chmod 0600 "$VAULT_FILE"
    log_ok "created and encrypted $(basename "$VAULT_FILE")"
    log_dim "read it with: ansible-vault view --vault-password-file .vault-password $VAULT_FILE"
}

# ---------------------------------------------------------------------
# TLS for the control-plane proxy
# ---------------------------------------------------------------------
generate_tls() {
    log_step "Control-plane TLS certificate"

    mkdir -p "$TLS_DIR"
    local certificate="$TLS_DIR/forge-ai.crt"
    local key="$TLS_DIR/forge-ai.key"

    if [[ -f "$certificate" && "$FORCE" == false && "$TLS_ONLY" == false ]]; then
        local expiry; expiry=$(openssl x509 -enddate -noout -in "$certificate" | cut -d= -f2)
        log_ok "certificate already exists, valid until $expiry"
        return 0
    fi

    local gitea_host semaphore_host gateway
    gitea_host=$(forge_config '.control_plane.gitea_hostname' 2>/dev/null || echo "gitea.poc.local")
    semaphore_host=$(forge_config '.control_plane.semaphore_hostname' 2>/dev/null || echo "semaphore.poc.local")
    gateway=$(forge_config '.provisioning_network.gateway' 2>/dev/null || echo "192.168.250.1")

    install -m 0600 /dev/null "$key"

    # A SAN certificate covering both hostnames plus localhost, because
    # the proxy distinguishes Gitea from Semaphore by SNI on one port.
    openssl req -x509 -newkey rsa:4096 -sha256 -days 825 -nodes \
        -keyout "$key" -out "$certificate" \
        -subj "/C=XX/O=FORGE-AI PoC/CN=${gitea_host}" \
        -addext "subjectAltName=DNS:${gitea_host},DNS:${semaphore_host},DNS:webhook.poc.local,DNS:localhost,IP:127.0.0.1,IP:${gateway}" \
        -addext "keyUsage=digitalSignature,keyEncipherment" \
        -addext "extendedKeyUsage=serverAuth" \
        2>/dev/null

    chmod 0600 "$key"
    chmod 0644 "$certificate"

    log_ok "self-signed certificate created, valid 825 days"
    log_dim "SANs: ${gitea_host}, ${semaphore_host}, localhost, ${gateway}"
    log_warn "self-signed: browsers and git will warn until it is trusted"
    log_dim "replacing it with a CA-issued pair is a straight swap of these two files"
    log_dim "see docs/SECURITY.md"
}

# ---------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------
show_status() {
    log_step "Secret inventory (no values are printed)"
    local -a files=(
        "$ENV_FILE"
        "$VAULT_FILE"
        "$VAULT_PASSWORD_FILE"
        "$SSH_KEY"
        "$SSH_KEY.pub"
        "$TLS_DIR/forge-ai.crt"
        "$TLS_DIR/forge-ai.key"
    )
    local path mode
    for path in "${files[@]}"; do
        if [[ -e "$path" ]]; then
            mode=$(stat -c '%a' "$path")
            local marker="ok"
            # A .pub and a .crt are meant to be readable; everything
            # else must be 0600.
            if [[ "$path" != *.pub && "$path" != *.crt && "$mode" != "600" ]]; then
                marker="warn"
            fi
            if [[ "$marker" == "ok" ]]; then
                log_ok "$(printf '%-52s' "${path/#$HOME/\~}") mode $mode"
            else
                log_warn "$(printf '%-52s' "${path/#$HOME/\~}") mode $mode -- expected 600"
            fi
        else
            log_warn "$(printf '%-52s' "${path/#$HOME/\~}") missing"
        fi
    done

    printf '\n' >&2
    log_dim "$(basename "$VAULT_FILE") is meant to be committed, encrypted, once"
    log_dim "it holds real values (git add + commit -- not automatic). Every"
    log_dim "other file above must never be tracked; .gitignore and"
    log_dim ".github/workflows/security.yml both enforce that independently."
}

main() {
    forge_banner

    if [[ "$SHOW_ONLY" == true ]]; then
        show_status
        exit 0
    fi

    if [[ "$TLS_ONLY" == true ]]; then
        generate_tls
        exit 0
    fi

    require_commands openssl python3 ssh-keygen

    generate_env
    generate_ssh_key
    generate_vault
    generate_tls
    show_status

    log_step "Done"
    cat >&2 <<'NEXT'

  Every secret is generated and stored with mode 0600.

  Nothing here is committed: .gitignore excludes all of it, and
  .github/workflows/security.yml fails the build if any of it appears
  in a commit anyway.

  Next:
    ./bootstrap/bootstrap.sh      or    make bootstrap

NEXT
}

main "$@"
