"""Build the variable context a template would receive from Ansible.

Rendering a template offline is only a meaningful test if the context
matches what Ansible actually provides. This module assembles that
context from the real configuration, plus the run-scoped variables the
playbooks set, plus the vault values a real run would decrypt.

Kept next to the fixtures rather than inside a test module so that
``scripts/render-templates.py`` can use the same builder -- one
definition of "what a template gets", used by both CI and the operator
tool.
"""

from __future__ import annotations

import base64
from typing import Any

# Values that would come from Ansible Vault. Obvious placeholders, so a
# leak into a rendered fixture is recognisable at a glance.
FIXTURE_VAULT: dict[str, Any] = {
    "vault_ubuntu_bootstrap_password": "FIXTURE-NOT-A-REAL-PASSWORD",
    # A real yescrypt-shaped hash so the format assertions are exercised.
    "vault_ubuntu_bootstrap_password_hash": (
        "$y$j9T$FIXTUREFIXTUREFIXTURE$FIXTUREFIXTUREFIXTUREFIXTUREFIXTUREFIXTUREFIXTUR"
    ),
    "vault_windows_admin_password": "FixturePassword123!Aa1",
    "vault_forge_state_token": "fixture-state-token",
    "vault_gitea_webhook_secret": "fixture-webhook-secret-at-least-32-chars",
    "vault_gitea_api_token": "fixture-gitea-token",
    "vault_semaphore_api_token": "fixture-semaphore-token",
    "vault_ssh_private_key_path": "/nonexistent/fixture-key",
}

FIXTURE_SSH_KEY = (
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREFIXTUREFIXTUREFIXTUREFIXTUREFIXT"
    " forge-ai-fixture"
)


def _windows_encoded_password(password: str) -> str:
    return base64.b64encode(f"{password}AdministratorPassword".encode("utf-16-le")).decode("ascii")


def build_context(config: dict, host: dict | None = None, **overrides: Any) -> dict:
    """Assemble the render context for a template.

    ``host`` is the per-host dict for templates that render once per
    host (the seeds, the answer files, the per-host iPXE scripts).
    """
    import sys
    from pathlib import Path

    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "lib"))
    import forge_config

    context: dict[str, Any] = {}

    # The dynamic inventory publishes every config key as a group var,
    # renaming the two that collide with Ansible play keywords.
    for key, value in forge_config.strip_meta(config).items():
        context["forge_hosts" if key == "hosts" else key] = value

    # Make sure the fixture always has an authorised key, even if the
    # example configuration ships an empty list.
    context.setdefault("security", {})
    if not context["security"].get("ssh_authorized_keys"):
        context["security"] = dict(context["security"], ssh_authorized_keys=[FIXTURE_SSH_KEY])

    # Run-scoped variables set by site.yml and group_vars/all.
    context.update(
        {
            "forge_boot_base_url": forge_config.boot_base_url(config),
            "forge_repo_root": "/opt/forge-ai",
            "forge_deployment_id": "fixture-20260101T000000Z",
            "forge_git_commit": "0123456789abcdef0123456789abcdef01234567",
            "forge_git_branch": "main",
            "forge_operator": "fixture",
            "forge_trigger": "pytest",
            # Supplied by group_vars/control_plane/main.yml.
            "forge_dnsmasq_service": "forge-dnsmasq",
            "forge_dnsmasq_config": "/etc/forge-ai/dnsmasq.conf",
            "forge_compose_file": "/opt/forge-ai/compose/docker-compose.yml",
            "forge_compose_env_file": "/opt/forge-ai/compose/.env",
            "pxe_dnsmasq_unit": "forge-dnsmasq",
            "pxe_dnsmasq_binary": "/usr/sbin/dnsmasq",
            "forge_state_token": FIXTURE_VAULT["vault_forge_state_token"],
            "ubuntu_bootstrap_password_hash": FIXTURE_VAULT["vault_ubuntu_bootstrap_password_hash"],
            "windows_admin_password_encoded": _windows_encoded_password(
                FIXTURE_VAULT["vault_windows_admin_password"]
            ),
            "inventory_hostname": (host or {}).get("name", "fixture-host"),
            # Ansible facts the templates reference.
            "ansible_date_time": {
                "iso8601": "2026-01-01T00:00:00Z",
                "epoch": "1767225600",
                "iso8601_basic_short": "20260101T000000",
            },
            "ansible_user_id": "forgeops",
        }
    )
    context.update(FIXTURE_VAULT)

    # Role defaults that templates reference.
    context.update(
        {
            "ipxe_bios_binary": "undionly.kpxe",
            "ipxe_efi_binary": "ipxe.efi",
            "ipxe_efi32_binary": "ipxe32.efi",
            "windows_media_share_name": "winmedia",
            "virtio_media_share_name": "virtio",
            "winpe_driver_inf_names": ["viostor.inf", "netkvm.inf"],
            "winpe_network_retries": 30,
            "windows_ui_language": "en-US",
            "windows_system_locale": "en-US",
            "windows_user_locale": "en-US",
            "windows_input_locale": "0409:00000409",
            "windows_timezone": "UTC",
            "windows_registered_owner": "FORGE-AI PoC",
            "windows_registered_org": "FORGE-AI",
            "windows_esp_size_mb": 260,
            "windows_msr_size_mb": 16,
            "winrm_cert_valid_years": 2,
            "winrm_max_timeout_ms": 1800000,
            "winrm_max_memory_mb": 1024,
            "winrm_max_shells": 30,
            "windows_attach_virtio_cdrom": False,
            "libvirt_emulator": "/usr/bin/qemu-system-x86_64",
            "forge_boot_target": "network",
            "state_service_port": 8090,
            "boot_server_max_body": "64m",
        }
    )

    if host is not None:
        context["host"] = host

    context.update(overrides)
    return context
