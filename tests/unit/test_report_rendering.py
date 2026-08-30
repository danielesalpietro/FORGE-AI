"""The deployment and drift reports.

A report is the only durable record of what a deployment produced, and
it matters most when the run partially failed -- so it has to render
from a partially-populated document, not just a happy-path one.
"""

from __future__ import annotations

import json
from xml.etree import ElementTree

import pytest


def make_report(status="success", failed_tasks=None):
    return {
        "deployment_id": "20260101T000000Z",
        "environment": "poc",
        "git_commit": "0123456789abcdef0123456789abcdef01234567",
        "git_branch": "main",
        "started_at": "2026-01-01T00:00:00Z",
        "finished_at": "2026-01-01T00:42:00Z",
        "duration_seconds": 2520,
        "operator": "operator",
        "trigger": "semaphore",
        "status": status,
        "semaphore_task_id": "42",
        "semaphore_task_url": "https://semaphore.poc.local:8443/project/1/history?t=42",
        "json_path": "/srv/forge-ai/reports/deployment-20260101T000000Z.json",
        "hosts": [
            {
                "name": "poc-ubuntu-01", "os": "Ubuntu Server 24.04.3",
                "profile": "ubuntu-server", "ip_address": "192.168.250.21",
                "mac_address": "52:54:00:25:00:21", "firmware": "uefi",
                "vcpu": 2, "memory_mb": 4096, "disk_gb": 40,
                "provisioning_result": "installed and reachable over SSH",
                "configuration_result": "baseline applied",
                "validation_result": "passed (12 checks)",
                "boot_state": "ready", "install_attempts": 1,
                "status": "success", "duration_seconds": 1200,
                "failed_tasks": failed_tasks or [],
                "facts": {"kernel": "6.8.0-51-generic", "distribution": "Ubuntu"},
            },
            {
                "name": "poc-windows-01", "os": "Windows Server 2025 SERVERSTANDARD",
                "profile": "windows-server", "ip_address": "192.168.250.22",
                "mac_address": "52:54:00:25:00:22", "firmware": "uefi",
                "vcpu": 4, "memory_mb": 8192, "disk_gb": 80,
                "provisioning_result": "installed and reachable over WinRM/HTTPS",
                "configuration_result": "baseline applied",
                "validation_result": "passed (7/7 probes)",
                "boot_state": "ready", "install_attempts": 2,
                "status": "success", "duration_seconds": 1800,
                "failed_tasks": [], "facts": {},
            },
        ],
        "media": [
            {"name": "Ubuntu Server ISO", "path": "/srv/forge-ai/iso/ubuntu.iso", "sha256": "a" * 64},
            {"name": "Windows Server ISO (operator supplied)", "path": "/srv/forge-ai/iso/win.iso", "sha256": "b" * 64},
        ],
        "versions": {"libvirt": "10.0.0", "qemu": "8.2.2", "ansible": "2.17.5"},
        "logs": [
            {"component": "dnsmasq", "location": "/srv/forge-ai/logs/dnsmasq.log", "hint": "DHCP and TFTP"},
            {"component": "Ansible", "location": "/srv/forge-ai/logs/ansible.log", "hint": ""},
        ],
    }


def make_drift(drifted=True):
    return {
        "run_id": "20260101T010000Z",
        "environment": "poc",
        "git_commit": "0123456789abcdef",
        "git_branch": "main",
        "executed_at": "2026-01-01T01:00:00Z",
        "executed_by": "operator",
        "mode": "check-mode + compliance probes",
        "drifted": drifted,
        "json_path": "/srv/forge-ai/reports/drift/drift-20260101T010000Z.json",
        "hosts": [
            {
                "name": "poc-ubuntu-01", "os_family": "linux",
                "ip_address": "192.168.250.21", "reachable": True,
                "drifted": drifted,
                "changed": [{"task": "Install the login banner", "resource": "/etc/issue.net",
                             "detail": "would restore the managed banner"}] if drifted else [],
                "probe_failures": [{"name": "login-banner", "expected": "FORGE-AI PoC",
                                    "observed": "edited by hand"}] if drifted else [],
                "check_mode_unsupported": ["command/shell tasks marked changed_when: false"],
            },
            {
                "name": "poc-windows-01", "os_family": "windows",
                "ip_address": "192.168.250.22", "reachable": True,
                "drifted": False, "changed": [], "probe_failures": [],
                "check_mode_unsupported": ["ansible.windows.win_shell (no check-mode support)"],
            },
        ],
    }


# ---------------------------------------------------------------------
# Markdown
# ---------------------------------------------------------------------


def test_markdown_report_renders(jinja_env):
    output = jinja_env.get_template("report/deployment-report.md.j2").render(report=make_report())

    assert "# FORGE-AI deployment report" in output
    assert "poc-ubuntu-01" in output and "poc-windows-01" in output
    assert "**SUCCESS**" in output


def test_markdown_report_records_the_audit_facts(jinja_env):
    """Deployment ID, commit, timestamps, operator, media checksums --
    the things that make a report evidence rather than decoration."""
    report = make_report()
    output = jinja_env.get_template("report/deployment-report.md.j2").render(report=report)

    assert report["deployment_id"] in output
    assert report["git_commit"] in output
    assert report["started_at"] in output and report["finished_at"] in output
    assert report["operator"] in output
    assert report["media"][0]["sha256"] in output
    assert report["semaphore_task_url"] in output


def test_markdown_report_shows_install_attempts(jinja_env):
    """A host that needed two attempts is invisible in a green pipeline
    and is exactly what someone reviewing a deployment wants to see."""
    output = jinja_env.get_template("report/deployment-report.md.j2").render(report=make_report())
    assert "| Install attempts | 2 |" in output


def test_markdown_report_lists_failed_tasks(jinja_env):
    report = make_report(
        status="failed",
        failed_tasks=[{"task": "Install the baseline packages", "msg": "apt lock held"}],
    )
    output = jinja_env.get_template("report/deployment-report.md.j2").render(report=report)

    assert "**Failed tasks (1):**" in output
    assert "apt lock held" in output
    assert "**FAILED**" in output


def test_markdown_report_handles_a_run_with_no_semaphore_link(jinja_env):
    """A CLI run has no task URL; the row must be omitted, not rendered
    as a broken link."""
    report = make_report()
    report["semaphore_task_url"] = ""
    output = jinja_env.get_template("report/deployment-report.md.j2").render(report=report)

    assert "Semaphore task" not in output


def test_markdown_report_records_log_locations(jinja_env):
    output = jinja_env.get_template("report/deployment-report.md.j2").render(report=make_report())
    assert "/srv/forge-ai/logs/dnsmasq.log" in output


# ---------------------------------------------------------------------
# HTML
# ---------------------------------------------------------------------


def test_html_report_is_well_formed(jinja_env):
    """Parsed as XML: stricter than a browser, which is the point."""
    output = jinja_env.get_template("report/deployment-report.html.j2").render(report=make_report())
    ElementTree.fromstring(output)


def test_html_report_is_theme_aware(jinja_env):
    """The report is read on whatever the operator's machine is set to."""
    output = jinja_env.get_template("report/deployment-report.html.j2").render(report=make_report())

    assert "prefers-color-scheme: dark" in output
    assert "color-scheme: light dark" in output


def test_html_report_carries_the_status(jinja_env):
    for status, expected_class in (("success", "ok"), ("failed", "fail")):
        output = jinja_env.get_template("report/deployment-report.html.j2").render(
            report=make_report(status=status)
        )
        assert f'data-status="{status}"' in output
        assert f'class="badge {expected_class}"' in output


def test_html_report_scrolls_wide_tables_internally(jinja_env):
    """A report whose body scrolls horizontally is unreadable on a phone."""
    output = jinja_env.get_template("report/deployment-report.html.j2").render(report=make_report())
    assert "overflow-x:auto" in output.replace(" ", "")


# ---------------------------------------------------------------------
# Drift
# ---------------------------------------------------------------------


def test_drift_report_renders_when_drift_is_found(jinja_env):
    output = jinja_env.get_template("report/drift-report.md.j2").render(drift=make_drift(True))

    assert "**DRIFT DETECTED**" in output
    assert "poc-ubuntu-01 — DRIFTED" in output
    assert "poc-windows-01 — in sync" in output
    assert "edited by hand" in output


def test_drift_report_renders_when_in_sync(jinja_env):
    output = jinja_env.get_template("report/drift-report.md.j2").render(drift=make_drift(False))

    assert "**IN SYNC**" in output
    assert "DRIFT DETECTED" not in output


def test_drift_report_states_its_blind_spots(jinja_env):
    """Claiming full coverage when win_shell has no check-mode support
    would make the report actively misleading."""
    output = jinja_env.get_template("report/drift-report.md.j2").render(drift=make_drift(True))

    assert "Check-mode blind spots" in output
    assert "no check-mode support" in output


def test_drift_report_says_reconciliation_is_not_automatic(jinja_env):
    output = jinja_env.get_template("report/drift-report.md.j2").render(drift=make_drift(True))

    assert "not** automatic" in output or "not automatic" in output
    assert "do not reconcile it away" in output


def test_drift_report_distinguishes_probe_failures_from_check_mode(jinja_env):
    """The two sources have different reliability, so the report must not
    merge them into one undifferentiated number."""
    output = jinja_env.get_template("report/drift-report.md.j2").render(drift=make_drift(True))

    assert "Changed resources (check mode)" in output
    assert "Compliance probe failures" in output


# ---------------------------------------------------------------------
# JSON shape
# ---------------------------------------------------------------------


def test_the_report_document_is_json_serialisable(jinja_env):
    """The JSON sibling is what automation consumes."""
    parsed = json.loads(json.dumps(make_report()))
    assert parsed["hosts"][0]["boot_state"] == "ready"

    drift = json.loads(json.dumps(make_drift()))
    assert drift["hosts"][0]["probe_failures"][0]["observed"] == "edited by hand"
