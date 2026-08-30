# =====================================================================
# FORGE-AI :: GitOps infrastructure provisioning
# =====================================================================
#   make help      every target, grouped, with a one-line description
#   make check     can this host run the PoC?  (read-only)
#   make deploy    the whole lifecycle
# =====================================================================

SHELL := /bin/bash
.SHELLFLAGS := -Eeuo pipefail -c
.DEFAULT_GOAL := help
.ONESHELL:

# ---------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------
REPO_ROOT     := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
ANSIBLE_DIR   := $(REPO_ROOT)/ansible
COMPOSE_FILE  := $(REPO_ROOT)/compose/docker-compose.yml
ENV_FILE      := $(REPO_ROOT)/compose/.env
VAULT_PASSWORD:= $(REPO_ROOT)/.vault-password
VENV          := $(REPO_ROOT)/.venv

# Select a different environment:  make deploy FORGE_CONFIG=config/lab.yml
FORGE_CONFIG ?=
export FORGE_CONFIG

# Extra arguments for any ansible-playbook target:
#   make provision ANSIBLE_ARGS="--limit poc-ubuntu-01 -vv"
ANSIBLE_ARGS ?=

# The destroy targets require this to be passed explicitly.
CONFIRM ?=

# Prefer the project virtualenv when it exists.
ANSIBLE_PLAYBOOK := $(shell test -x "$(VENV)/bin/ansible-playbook" \
                      && echo "$(VENV)/bin/ansible-playbook" || echo ansible-playbook)
PYTHON           := $(shell test -x "$(VENV)/bin/python" \
                      && echo "$(VENV)/bin/python" || echo python3)
PYTEST           := $(shell test -x "$(VENV)/bin/pytest" \
                      && echo "$(VENV)/bin/pytest" || echo "python3 -m pytest")

VAULT_ARG := $(shell test -f "$(VAULT_PASSWORD)" \
               && echo "--vault-password-file $(VAULT_PASSWORD)" || echo "")

COMPOSE := docker compose --env-file "$(ENV_FILE)" -f "$(COMPOSE_FILE)"

# Add the windows profile only when the operator supplied a Windows ISO.
WINDOWS_PROFILE = $(shell $(REPO_ROOT)/scripts/validate-config.py --json --quiet 2>/dev/null \
                    | jq -r 'if (.media.windows.iso_path // "") != "" then "--profile windows" else "" end' 2>/dev/null)

# Colours, suppressed when stdout is not a terminal.
ifneq ($(shell test -t 1 && echo tty),)
  BOLD  := \033[1m
  DIM   := \033[2m
  GREEN := \033[32m
  BLUE  := \033[34m
  RESET := \033[0m
else
  BOLD :=
  DIM :=
  GREEN :=
  BLUE :=
  RESET :=
endif

define banner
	@printf '$(BOLD)==> %s$(RESET)\n' "$(1)"
endef

define run_playbook
	cd "$(ANSIBLE_DIR)" && $(ANSIBLE_PLAYBOOK) playbooks/$(1) $(VAULT_ARG) $(ANSIBLE_ARGS)
endef

# =====================================================================
# Help
# =====================================================================
##@ Getting started

.PHONY: help
help: ## Show this help
	@printf '\n$(BOLD)FORGE-AI$(RESET) -- GitOps infrastructure provisioning PoC\n\n'
	@awk 'BEGIN {FS = ":.*##"} \
	  /^##@/ { printf "\n$(BOLD)%s$(RESET)\n", substr($$0, 5); next } \
	  /^[a-zA-Z0-9_-]+:.*?##/ { printf "  $(BLUE)%-24s$(RESET) %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)
	@printf '\n$(BOLD)Typical first run$(RESET)\n'
	@printf '  $(DIM)cp compose/.env.example compose/.env$(RESET)\n'
	@printf '  $(DIM)cp config/poc.example.yml config/poc.yml$(RESET)\n'
	@printf '  make check          $(DIM)# can this host do it?$(RESET)\n'
	@printf '  make bootstrap      $(DIM)# secrets, network, control plane$(RESET)\n'
	@printf '  make prepare-media  $(DIM)# download and unpack the installers$(RESET)\n'
	@printf '  make provision      $(DIM)# create the VMs and install both OSes$(RESET)\n'
	@printf '  make validate       $(DIM)# smoke tests and the deployment report$(RESET)\n\n'
	@printf '$(BOLD)Variables$(RESET)\n'
	@printf '  $(BLUE)%-24s$(RESET) %s\n' "FORGE_CONFIG=path" "use a different configuration overlay"
	@printf '  $(BLUE)%-24s$(RESET) %s\n' "ANSIBLE_ARGS=\"...\"" "extra ansible-playbook arguments"
	@printf '  $(BLUE)%-24s$(RESET) %s\n' "CONFIRM=DESTROY-POC" "required by the destroy targets"
	@printf '\n'

# =====================================================================
# Validation -- read-only, no hypervisor needed
# =====================================================================
##@ Validation

.PHONY: check
check: ## Check this host can run the PoC (read-only, changes nothing)
	@./bootstrap/check-prerequisites.sh

.PHONY: validate
validate: validate-config validate-templates validate-syntax test ## Everything CI runs, locally
	$(call banner,All validation passed)

.PHONY: validate-config
validate-config: ## Validate config/poc.yml against the schema and the semantic rules
	$(call banner,Configuration)
	@$(PYTHON) scripts/validate-config.py $(if $(FORGE_CONFIG),--config $(FORGE_CONFIG),)

.PHONY: validate-templates
validate-templates: ## Render every Jinja2 template and parse the result
	$(call banner,Templates)
	@$(PYTHON) scripts/render-templates.py --check --quiet

.PHONY: validate-syntax
validate-syntax: ## Ansible syntax check on every playbook
	$(call banner,Ansible syntax)
	@cd "$(ANSIBLE_DIR)" && for playbook in playbooks/*.yml; do \
	    $(ANSIBLE_PLAYBOOK) --syntax-check "$$playbook" >/dev/null \
	      && printf '  ok    %s\n' "$$playbook" \
	      || { printf '  FAIL  %s\n' "$$playbook"; exit 1; }; \
	  done

.PHONY: lint
lint: lint-yaml lint-ansible lint-shell lint-compose ## Run every linter
	$(call banner,Lint clean)

.PHONY: lint-yaml
lint-yaml: ## yamllint
	@yamllint -c .yamllint config/ ansible/ compose/ tests/ .github/

.PHONY: lint-ansible
lint-ansible: ## ansible-lint (production profile)
	@cd "$(ANSIBLE_DIR)" && ansible-lint --offline

.PHONY: lint-shell
lint-shell: ## ShellCheck every script
	@shellcheck -x -P bootstrap:.:scripts \
	  bootstrap/*.sh bootstrap/lib/*.sh scripts/*.sh compose/database/init/*.sh
	@printf '  ok    %s scripts\n' "$$(ls bootstrap/*.sh bootstrap/lib/*.sh scripts/*.sh | wc -l)"

.PHONY: lint-compose
lint-compose: ## Validate the Docker Compose file
	@test -f "$(ENV_FILE)" || { echo "compose/.env is missing; run: cp compose/.env.example compose/.env"; exit 1; }
	@$(COMPOSE) config --quiet && printf '  ok    docker-compose.yml\n'

.PHONY: test
test: ## Unit and shell tests (no hypervisor needed)
	$(call banner,Unit tests)
	@$(PYTEST) tests/unit -q
	@command -v bats >/dev/null 2>&1 \
	  && { printf '\n'; $(call banner,Shell tests); bats tests/bats/; } \
	  || printf '  $(DIM)bats is not installed; shell tests skipped$(RESET)\n'

.PHONY: test-integration
test-integration: ## Integration tests against a live control plane
	@$(PYTEST) tests/integration -m integration -v

.PHONY: test-molecule
test-molecule: ## Molecule scenario for the Ubuntu baseline (needs Docker)
	@cd tests/molecule/ubuntu_baseline && molecule test

# =====================================================================
# Bootstrap
# =====================================================================
##@ Bootstrap

.PHONY: install-host
install-host: ## Install the host packages (add DOCKER=1 for Docker Engine)
	@./bootstrap/prepare-host.sh $(if $(DOCKER),--install-docker,)

.PHONY: secrets
secrets: ## Generate every secret (idempotent; never overwrites without --force)
	@./bootstrap/create-secrets.sh

.PHONY: secrets-show
secrets-show: ## Report which secrets exist, without printing any value
	@./bootstrap/create-secrets.sh --show

.PHONY: bootstrap
bootstrap: ## Secrets, provisioning network, control plane, Gitea and Semaphore
	@./bootstrap/bootstrap.sh

.PHONY: deploy-control-plane
deploy-control-plane: ## Start the Docker control plane only
	$(call banner,Control plane)
	@test -f "$(ENV_FILE)" || { echo "compose/.env is missing; run: make secrets"; exit 1; }
	@grep -q '=CHANGEME' "$(ENV_FILE)" \
	  && { echo "compose/.env still has placeholder values; run: make secrets"; exit 1; } || true
	@$(COMPOSE) $(WINDOWS_PROFILE) up -d --wait
	@$(COMPOSE) ps

.PHONY: deploy-pxe
deploy-pxe: ## Deploy the PXE services and render the boot scripts
	@$(call run_playbook,deploy-pxe-stack.yml)

# =====================================================================
# Media
# =====================================================================
##@ Installation media

.PHONY: prepare-media
prepare-media: prepare-ubuntu-media prepare-windows-media ## Prepare all installation media

.PHONY: prepare-ubuntu-media
prepare-ubuntu-media: ## Download, verify and unpack the Ubuntu Server ISO
	@$(call run_playbook,prepare-ubuntu-media.yml)

.PHONY: prepare-windows-media
prepare-windows-media: ## Validate the operator-supplied Windows ISO and build WinPE
	@$(call run_playbook,prepare-windows-media.yml)

.PHONY: windows-images
windows-images: ## List the editions inside the Windows install.wim
	@./scripts/prepare-windows-iso.sh --list-images

.PHONY: verify-checksums
verify-checksums: ## Verify every downloaded artefact against its pinned checksum
	@./scripts/verify-checksums.sh

# =====================================================================
# Provisioning
# =====================================================================
##@ Provisioning

.PHONY: deploy
deploy: ## The whole lifecycle: validate, media, VMs, install, configure, report
	@$(call run_playbook,site.yml)

.PHONY: create-vms
create-vms: ## Define and start the target virtual machines
	@$(call run_playbook,create-vms.yml)

.PHONY: provision
provision: provision-ubuntu provision-windows ## Install both operating systems

.PHONY: provision-ubuntu
provision-ubuntu: ## Network-boot and install Ubuntu Server
	@$(call run_playbook,provision-ubuntu.yml)

.PHONY: provision-windows
provision-windows: ## Network-boot and install Windows Server
	@$(call run_playbook,provision-windows.yml)

.PHONY: configure
configure: ## Apply the baseline configuration to every target
	@$(call run_playbook,configure-targets.yml)

.PHONY: state
state: ## Show each host's provisioning lifecycle state
	@./scripts/set-boot-state.sh

.PHONY: console
console: ## Attach to a VM's serial console (make console HOST=poc-ubuntu-01)
	@test -n "$(HOST)" || { echo "usage: make console HOST=poc-ubuntu-01"; exit 2; }
	@printf '$(DIM)Ctrl+] to detach$(RESET)\n'
	@virsh --connect qemu:///system console "$(HOST)"

# =====================================================================
# Validation and drift
# =====================================================================
##@ Verification and drift

.PHONY: validate-deployment
validate-deployment: ## Smoke tests, idempotence check and the deployment report
	@$(call run_playbook,validate-deployment.yml)

.PHONY: smoke-test
smoke-test: ## Verify both targets by reading them
	@./scripts/smoke-test.sh

.PHONY: drift
drift: ## Detect drift. Changes nothing.
	@./scripts/drift-check.sh

.PHONY: drift-report
drift-report: ## Re-read the most recent drift report
	@./scripts/drift-check.sh --show

.PHONY: reconcile
reconcile: ## Reapply the desired state, then prove it took
	@$(call run_playbook,reconcile.yml)

.PHONY: report
report: ## Print the most recent deployment report
	@report=$$($(PYTHON) scripts/validate-config.py --json --quiet | jq -r '.storage.report_dir')/latest.md; \
	 test -r "$$report" && cat "$$report" \
	   || { echo "no report at $$report -- run 'make validate-deployment' first"; exit 1; }

# =====================================================================
# Teardown
# =====================================================================
##@ Teardown

.PHONY: destroy
destroy: ## Remove the VMs, PXE services and network (needs CONFIRM=DESTROY-POC)
	@test "$(CONFIRM)" = "DESTROY-POC" || { \
	  printf 'Refusing to destroy anything.\n\n'; \
	  printf '  make destroy CONFIRM=DESTROY-POC\n\n'; \
	  printf 'This removes the target VMs and their disks. It cannot be undone.\n'; \
	  exit 1; }
	@./scripts/destroy.sh --yes

.PHONY: destroy-all
destroy-all: ## Also remove the media and the control plane (needs CONFIRM=DESTROY-POC)
	@test "$(CONFIRM)" = "DESTROY-POC" || { \
	  printf 'Refusing to destroy anything.\n\n'; \
	  printf '  make destroy-all CONFIRM=DESTROY-POC\n\n'; \
	  printf 'This additionally removes the prepared media and the Docker control\n'; \
	  printf 'plane. Deployment reports are kept.\n'; \
	  exit 1; }
	@./scripts/destroy.sh --media --all --yes

.PHONY: clean
clean: ## Remove local build artefacts (touches no deployed state)
	$(call banner,Cleaning local artefacts)
	@rm -rf .pytest_cache .ruff_cache .mypy_cache htmlcov .coverage
	@find . -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
	@find . -name '*.retry' -delete 2>/dev/null || true
	@rm -rf /tmp/forge-ai-facts
	@printf '  ok    nothing deployed was touched\n'

# =====================================================================
# Control plane operations
# =====================================================================
##@ Control plane

.PHONY: up
up: deploy-control-plane ## Alias for deploy-control-plane

.PHONY: down
down: ## Stop the control plane (keeps volumes and data)
	@$(COMPOSE) $(WINDOWS_PROFILE) down

.PHONY: ps
ps: ## Show the control-plane container states
	@$(COMPOSE) $(WINDOWS_PROFILE) ps

.PHONY: logs
logs: ## Follow the control-plane logs (make logs SERVICE=state)
	@$(COMPOSE) logs -f --tail=100 $(SERVICE)

.PHONY: restart
restart: ## Restart a control-plane service (make restart SERVICE=bootsrv)
	@test -n "$(SERVICE)" || { echo "usage: make restart SERVICE=bootsrv"; exit 2; }
	@$(COMPOSE) restart "$(SERVICE)"

# =====================================================================
# Development
# =====================================================================
##@ Development

.PHONY: render
render: ## Render every template to /tmp/forge-rendered for inspection
	@$(PYTHON) scripts/render-templates.py --out /tmp/forge-rendered

.PHONY: inventory
inventory: ## Show the inventory the dynamic source produces
	@cd "$(ANSIBLE_DIR)" && ansible-inventory --list --yaml

.PHONY: facts
facts: ## Show the merged configuration as JSON
	@$(PYTHON) scripts/validate-config.py --json --quiet

.PHONY: collections
collections: ## Install the Ansible collections
	@cd "$(ANSIBLE_DIR)" && ansible-galaxy collection install -r requirements.yml -p ./collections

.PHONY: version
version: ## Show the versions of every component
	@printf '$(BOLD)FORGE-AI component versions$(RESET)\n\n'
	@printf '  %-18s %s\n' "ansible-core" "$$(ansible --version 2>/dev/null | head -1 | grep -o '[0-9.]*' | head -1 || echo 'not installed')"
	@printf '  %-18s %s\n' "python" "$$($(PYTHON) --version 2>&1 | cut -d' ' -f2)"
	@printf '  %-18s %s\n' "docker" "$$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',' || echo 'not installed')"
	@printf '  %-18s %s\n' "compose" "$$(docker compose version --short 2>/dev/null || echo 'not installed')"
	@printf '  %-18s %s\n' "libvirt" "$$(virsh --version 2>/dev/null || echo 'not installed')"
	@printf '  %-18s %s\n' "qemu" "$$(qemu-system-x86_64 --version 2>/dev/null | head -1 | cut -d' ' -f4 || echo 'not installed')"
	@printf '\n  Tested combinations: docs/COMPATIBILITY.md\n\n'
