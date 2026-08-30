#!/usr/bin/env bash
# =====================================================================
# FORGE-AI :: devcontainer setup
# =====================================================================
# Runs once, after the container is created. Installs the toolchain
# needed to lint, test and render -- not to deploy.
# =====================================================================
set -Eeuo pipefail

readonly REPO_ROOT="${PWD}"

log() { printf '\033[34m[ .. ]\033[0m %s\n' "$*"; }
ok()  { printf '\033[32m[ ok ]\033[0m %s\n' "$*"; }

log "Installing the system packages"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    shellcheck \
    bats \
    jq \
    libxml2-utils \
    p7zip-full \
    wimtools \
    whois \
    openssl \
    make \
    tree \
    >/dev/null
ok "system packages"

log "Installing the Python toolchain"
python3 -m pip install --quiet --upgrade pip
# The `ansible` distribution bundles the collections this project needs,
# so the container does not depend on Galaxy being reachable.
python3 -m pip install --quiet \
    "ansible>=10,<13" \
    "ansible-lint>=24.7,<26" \
    "yamllint>=1.35,<2" \
    "pytest>=8.2,<9" \
    "jsonschema>=4.21,<5" \
    "PyYAML>=6.0,<7" \
    "Jinja2>=3.1.4,<4" \
    "molecule>=24.2,<26" \
    "molecule-plugins[docker]>=23.5,<24"
ok "python toolchain"

log "Installing markdownlint"
sudo npm install -g --silent markdownlint-cli@0.42.0 >/dev/null 2>&1 || true
ok "markdownlint"

log "Preparing the configuration"
if [[ ! -f "${REPO_ROOT}/config/poc.yml" ]]; then
    cp "${REPO_ROOT}/config/poc.example.yml" "${REPO_ROOT}/config/poc.yml"
    ok "created config/poc.yml from the example"
fi

log "Verifying the toolchain"
failures=0
check() {
    if command -v "$1" >/dev/null 2>&1; then
        printf '  %-16s %s\n' "$1" "$("${@:2}" 2>&1 | head -1)"
    else
        printf '  %-16s MISSING\n' "$1"
        failures=$((failures + 1))
    fi
}
check ansible          ansible --version
check ansible-lint     ansible-lint --version
check yamllint         yamllint --version
check shellcheck       shellcheck --version
check bats             bats --version
check pytest           pytest --version
check jq               jq --version
check xmllint          xmllint --version
check wimlib-imagex    wimlib-imagex --version

log "Running the validation suite"
if make validate >/dev/null 2>&1; then
    ok "make validate passes"
else
    printf '\033[33m[warn]\033[0m make validate did not pass; run it directly to see why\n'
fi

cat <<'BANNER'

  ================================================================
   FORGE-AI devcontainer ready
  ================================================================

   This container is for WORKING ON the repository:

     make validate     schema, templates, syntax, unit tests
     make lint         yamllint, ansible-lint, ShellCheck
     make test         unit and shell tests
     make render       render every template to /tmp/forge-rendered
     make help         everything else

   It CANNOT deploy anything. There is no /dev/kvm in a
   devcontainer, so provisioning needs a real Ubuntu 24.04 host
   with hardware virtualisation. See docs/QUICKSTART.md.

  ================================================================

BANNER

exit $failures
