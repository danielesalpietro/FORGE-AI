"""Every Jinja2 template must render, and what it renders must parse.

A template that renders into malformed YAML or XML fails at the worst
possible moment: after a VM has booted, on a machine with no console.
These tests catch that in CI, in under a second, with no hypervisor.

Rendering uses StrictUndefined, so a variable the template needs but no
role provides is a test failure rather than a silently empty string.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "fixtures"))
import render_context  # noqa: E402

TEMPLATE_ROOT = Path(__file__).resolve().parents[2] / "ansible" / "templates"

# Templates rendered once, with no per-host context.
GLOBAL_TEMPLATES = [
    "dnsmasq/provisioning.conf.j2",
    "dnsmasq/forge-dnsmasq.service.j2",
    "ipxe/boot.ipxe.j2",
    "ipxe/menu.ipxe.j2",
    "nginx/boot-server.conf.j2",
    "libvirt/network.xml.j2",
    "semaphore/environment.json.j2",
]

# Templates rendered once per host, and which os_family they apply to.
PER_HOST_TEMPLATES = [
    ("ubuntu/user-data.j2", "linux"),
    ("ubuntu/meta-data.j2", "linux"),
    ("ubuntu/vendor-data.j2", "linux"),
    ("ipxe/host-ubuntu-install.ipxe.j2", "linux"),
    ("windows/Autounattend.xml.j2", "windows"),
    ("windows/SetupComplete.cmd.j2", "windows"),
    ("windows/Configure-WinRM.ps1.j2", "windows"),
    ("windows/startnet.cmd.j2", "windows"),
    ("ipxe/host-windows-install.ipxe.j2", "windows"),
]

# Rendered once per host by their own tests below.
DOMAIN_TEMPLATE = "libvirt/domain.xml.j2"

# Rendered from a report document rather than the configuration; covered
# by tests/unit/test_report_rendering.py.
REPORT_TEMPLATES = [
    "report/deployment-report.md.j2",
    "report/deployment-report.html.j2",
    "report/drift-report.md.j2",
]


def hosts_of(config, family):
    return [h for h in config["hosts"] if h["os_family"] == family]


# ---------------------------------------------------------------------
# Coverage: no template may be added without a test
# ---------------------------------------------------------------------


def test_every_template_is_covered_by_a_test():
    """A new template with no test is the failure mode this guards."""
    on_disk = {
        str(path.relative_to(TEMPLATE_ROOT))
        for path in TEMPLATE_ROOT.rglob("*.j2")
    }
    covered = set(GLOBAL_TEMPLATES)
    covered |= {name for name, _ in PER_HOST_TEMPLATES}
    covered |= {DOMAIN_TEMPLATE}
    covered |= set(REPORT_TEMPLATES)

    uncovered = on_disk - covered
    assert uncovered == set(), (
        f"these templates have no rendering test: {sorted(uncovered)}. "
        "Add them to GLOBAL_TEMPLATES or PER_HOST_TEMPLATES."
    )


# ---------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------


@pytest.mark.parametrize("template_name", GLOBAL_TEMPLATES)
def test_global_template_renders(jinja_env, base_config, template_name):
    context = render_context.build_context(base_config)
    output = jinja_env.get_template(template_name).render(**context)
    assert output.strip(), f"{template_name} rendered empty"


@pytest.mark.parametrize("template_name,family", PER_HOST_TEMPLATES)
def test_per_host_template_renders(jinja_env, base_config, template_name, family):
    for host in hosts_of(base_config, family):
        context = render_context.build_context(base_config, host=host)
        output = jinja_env.get_template(template_name).render(**context)
        assert output.strip(), f"{template_name} rendered empty for {host['name']}"


def test_libvirt_domain_renders_for_every_host(jinja_env, base_config):
    for host in base_config["hosts"]:
        context = render_context.build_context(base_config, host=host)
        output = jinja_env.get_template("libvirt/domain.xml.j2").render(**context)
        assert host["name"] in output
        assert host["mac_address"] in output


# ---------------------------------------------------------------------
# The Ubuntu autoinstall seed must be valid YAML with the right shape
# ---------------------------------------------------------------------


def test_autoinstall_seed_is_valid_yaml(jinja_env, base_config):
    for host in hosts_of(base_config, "linux"):
        context = render_context.build_context(base_config, host=host)
        rendered = jinja_env.get_template("ubuntu/user-data.j2").render(**context)

        parsed = yaml.safe_load(rendered)

        assert isinstance(parsed, dict), "the seed must be a YAML mapping"
        assert "autoinstall" in parsed, "Subiquity requires a top-level autoinstall key"


def test_autoinstall_seed_carries_every_mandatory_key(jinja_env, base_config):
    """A missing key makes Subiquity drop to an interactive prompt, which
    on a headless VM is indistinguishable from a hang."""
    for host in hosts_of(base_config, "linux"):
        context = render_context.build_context(base_config, host=host)
        parsed = yaml.safe_load(
            jinja_env.get_template("ubuntu/user-data.j2").render(**context)
        )["autoinstall"]

        assert parsed["version"] == 1
        assert parsed["identity"]["hostname"] == host["name"]
        assert parsed["identity"]["username"] == base_config["users"]["automation_user"]
        assert parsed["ssh"]["install-server"] is True
        assert parsed["ssh"]["allow-pw"] is False
        assert len(parsed["ssh"]["authorized-keys"]) >= 1
        assert parsed["storage"]["config"], "no storage layout means an interactive prompt"
        assert parsed["late-commands"], "no late-commands means no state callback"
        assert parsed["interactive-sections"] == [], "must be fully unattended"


def test_autoinstall_seed_contains_a_hash_not_a_password(jinja_env, base_config):
    """The seed is served over HTTP and ends up in /var/log/installer.
    A cleartext password there would be a real exposure."""
    for host in hosts_of(base_config, "linux"):
        context = render_context.build_context(base_config, host=host)
        rendered = jinja_env.get_template("ubuntu/user-data.j2").render(**context)

        cleartext = render_context.FIXTURE_VAULT["vault_ubuntu_bootstrap_password"]
        assert cleartext not in rendered, "a cleartext password reached the seed"

        parsed = yaml.safe_load(rendered)["autoinstall"]
        assert parsed["identity"]["password"].startswith("$"), "must be a crypt(3) hash"


def test_autoinstall_seed_reports_state_on_success_and_failure(jinja_env, base_config):
    """Without the callback the host reinstalls on its next boot."""
    for host in hosts_of(base_config, "linux"):
        context = render_context.build_context(base_config, host=host)
        parsed = yaml.safe_load(
            jinja_env.get_template("ubuntu/user-data.j2").render(**context)
        )["autoinstall"]

        late = " ".join(str(c) for c in parsed["late-commands"])
        assert "/api/state/" in late
        assert '"state":"installed"' in late.replace(" ", "")

        errors = " ".join(str(c) for c in parsed["error-commands"])
        assert '"state":"failed"' in errors.replace(" ", "")


def test_autoinstall_seed_hardens_ssh_before_first_boot(jinja_env, base_config):
    for host in hosts_of(base_config, "linux"):
        context = render_context.build_context(base_config, host=host)
        parsed = yaml.safe_load(
            jinja_env.get_template("ubuntu/user-data.j2").render(**context)
        )["autoinstall"]

        late = " ".join(str(c) for c in parsed["late-commands"])
        assert "PasswordAuthentication no" in late
        assert "PermitRootLogin no" in late


def test_meta_data_is_valid_yaml_with_a_unique_instance_id(jinja_env, base_config):
    seen = set()
    for host in hosts_of(base_config, "linux"):
        context = render_context.build_context(base_config, host=host)
        parsed = yaml.safe_load(
            jinja_env.get_template("ubuntu/meta-data.j2").render(**context)
        )
        assert parsed["local-hostname"] == host["name"]
        assert parsed["instance-id"] not in seen
        seen.add(parsed["instance-id"])
