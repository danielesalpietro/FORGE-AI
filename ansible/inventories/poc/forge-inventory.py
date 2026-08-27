#!/usr/bin/env python3
"""FORGE-AI dynamic inventory: config/poc.yml is the single source of truth.

Ansible calls this with ``--list`` (and, for older tooling, ``--host``).
It reads ``config/defaults.yml`` merged with ``config/poc.yml`` -- the
exact same loader the validator and the tests use -- and turns the
``hosts:`` list into a real inventory.

Why a script instead of a static ``hosts.yml``:

  A static inventory would restate every IP address, MAC address and
  connection setting that already exists in ``config/poc.yml``. The two
  copies would drift, and drift in an inventory is how a playbook ends
  up configuring the wrong machine. Here there is one definition.

Groups produced
---------------

    all
      forge_targets          every provisioned VM
        linux                os_family == linux
          ubuntu_server      profile == ubuntu-server
        windows              os_family == windows
          windows_server     profile == windows-server
      control_plane          the KVM host itself (localhost)

Group variables
---------------

The whole merged configuration is attached to ``all`` so templates can
reach ``deployment.name``, ``provisioning_network.cidr`` and so on.
Two keys are renamed on the way in because Ansible reserves them as play
keywords:

    hosts        -> forge_hosts
    environment  -> deployment   (already renamed in the config itself)

Refusing to start
-----------------

If the configuration does not validate, this script exits non-zero with
the findings on stderr. Combined with ``any_unparsed_is_failed`` in
``ansible.cfg``, that means an invalid desired state cannot reach a
target: the run stops at inventory parse time.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "lib"))

try:
    import forge_config
except ImportError as exc:  # pragma: no cover - import guard
    print(f"forge-inventory: cannot import the configuration loader: {exc}", file=sys.stderr)
    print(f"                 expected it at {REPO_ROOT / 'scripts' / 'lib' / 'forge_config.py'}", file=sys.stderr)
    raise SystemExit(2) from exc


# Config keys that must not be published under their own name because
# Ansible treats them as play/task keywords.
RESERVED_RENAMES = {"hosts": "forge_hosts"}


def build_group_vars(config: dict) -> dict:
    group_vars: dict = {}
    for key, value in forge_config.strip_meta(config).items():
        group_vars[RESERVED_RENAMES.get(key, key)] = value

    # Convenience values every role and template expects.
    control = config.get("control_plane", {}) or {}
    storage = config.get("storage", {}) or {}
    group_vars["forge_boot_base_url"] = forge_config.boot_base_url(config)
    group_vars["forge_repo_root"] = str(REPO_ROOT)
    group_vars["forge_state_url"] = f"{forge_config.boot_base_url(config)}/api/state"
    group_vars["forge_artifacts_dir"] = storage.get("artifacts_dir", "/srv/forge-ai")
    group_vars["forge_gitea_url"] = f"https://{control.get('gitea_hostname')}:{control.get('proxy_https_port', 8443)}"
    group_vars["forge_semaphore_url"] = f"https://{control.get('semaphore_hostname')}:{control.get('proxy_https_port', 8443)}"
    return group_vars


def connection_vars(host: dict, config: dict) -> dict:
    """Per-host connection settings, derived rather than restated."""
    security = config.get("security", {}) or {}
    users = config.get("users", {}) or {}

    common = {
        "ansible_host": host["ip_address"],
        "forge_host": host,
        "forge_mac_hyphen": str(host["mac_address"]).lower().replace(":", "-"),
    }

    if host.get("os_family") == "windows":
        transport = security.get("winrm_transport", "https")
        if transport == "psrp":
            common.update({
                "ansible_connection": "community.general.psrp",
                "ansible_psrp_protocol": "https",
                "ansible_psrp_port": security.get("winrm_port", 5986),
                "ansible_psrp_auth": "ntlm",
                "ansible_psrp_cert_validation": security.get("winrm_cert_validation", "ignore"),
            })
        else:
            common.update({
                "ansible_connection": "winrm",
                "ansible_port": security.get("winrm_port", 5986),
                "ansible_winrm_transport": "ntlm",
                "ansible_winrm_scheme": "https" if transport == "https" else "http",
                # PoC boundary: the specialize-phase certificate is
                # self-signed. docs/SECURITY.md explains what "validate"
                # requires instead.
                "ansible_winrm_server_cert_validation": security.get("winrm_cert_validation", "ignore"),
                "ansible_winrm_read_timeout_sec": 90,
                "ansible_winrm_operation_timeout_sec": 60,
            })
        common["ansible_user"] = users.get("windows_admin_user", "Administrator")
        common["ansible_shell_type"] = "powershell"
        # ansible_password comes from the vault, via group_vars/windows.
    else:
        common.update({
            "ansible_connection": "ssh",
            "ansible_port": 22,
            "ansible_user": users.get("automation_user", "forgeops"),
            "ansible_python_interpreter": "/usr/bin/python3",
            "ansible_ssh_common_args": "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null",
        })

    return common


def build_inventory(config: dict) -> dict:
    hosts = config.get("hosts", []) or []

    inventory: dict = {
        "_meta": {"hostvars": {}},
        "all": {"children": ["forge_targets", "control_plane", "ungrouped"]},
        "control_plane": {"hosts": ["forge-control"], "vars": {}},
        "forge_targets": {"hosts": [], "children": ["linux", "windows"], "vars": {}},
        "linux": {"hosts": [], "children": ["ubuntu_server"], "vars": {}},
        "ubuntu_server": {"hosts": [], "vars": {}},
        "windows": {"hosts": [], "children": ["windows_server"], "vars": {}},
        "windows_server": {"hosts": [], "vars": {}},
    }

    # Group vars for `all` are exposed through the special "all" group.
    inventory["all"]["vars"] = build_group_vars(config)

    # The KVM host. Everything that touches libvirt, dnsmasq or Docker
    # runs here, over a local connection.
    inventory["_meta"]["hostvars"]["forge-control"] = {
        "ansible_connection": "local",
        "ansible_host": "127.0.0.1",
        "ansible_python_interpreter": sys.executable,
        "forge_role": "control-plane",
    }

    for host in hosts:
        name = host["name"]
        inventory["forge_targets"]["hosts"].append(name)
        inventory["_meta"]["hostvars"][name] = connection_vars(host, config)

        if host.get("os_family") == "windows":
            inventory["windows"]["hosts"].append(name)
            if host.get("profile") == "windows-server":
                inventory["windows_server"]["hosts"].append(name)
        else:
            inventory["linux"]["hosts"].append(name)
            if host.get("profile") == "ubuntu-server":
                inventory["ubuntu_server"]["hosts"].append(name)

    return inventory


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="FORGE-AI dynamic inventory")
    parser.add_argument("--list", action="store_true", help="emit the whole inventory")
    parser.add_argument("--host", metavar="HOSTNAME", help="emit variables for one host")
    parser.add_argument("--pretty", action="store_true", help="indent the JSON output")
    args = parser.parse_args(argv)

    # `or None` matters: `make` exports FORGE_CONFIG even when it is
    # unset, so the variable arrives as an empty string. Treating that
    # as a real path silently loads defaults-only, which has no hosts,
    # and the inventory then refuses to build for a reason that has
    # nothing to do with the operator's configuration.
    overlay = os.environ.get("FORGE_CONFIG") or None  # lets CI point at a fixture
    try:
        config = forge_config.load_config(overlay_path=overlay)
    except (FileNotFoundError, ValueError) as exc:
        print(f"forge-inventory: {exc}", file=sys.stderr)
        return 2

    result = forge_config.validate(config)
    if not result.ok:
        print("forge-inventory: refusing to build an inventory from an invalid configuration:", file=sys.stderr)
        for finding in result.errors:
            print(f"  {finding}", file=sys.stderr)
        print("  fix config/poc.yml, then re-run. 'make validate' reports the same findings.", file=sys.stderr)
        return 1

    if args.host:
        inventory = build_inventory(config)
        payload = inventory["_meta"]["hostvars"].get(args.host, {})
    else:
        payload = build_inventory(config)

    json.dump(payload, sys.stdout, indent=2 if args.pretty else None, sort_keys=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
