#!/usr/bin/env python3
"""Render every Jinja2 template offline, without Ansible.

Two uses:

  * **CI** -- prove that every template renders and that what it
    produces parses, on a runner with no hypervisor and no secrets.
  * **Debugging** -- see exactly what a template would produce for a
    given host, without waiting for a deployment.

        scripts/render-templates.py --check
        scripts/render-templates.py --out /tmp/rendered
        scripts/render-templates.py --template windows/Autounattend.xml.j2 --host poc-windows-01

Rendering uses StrictUndefined, so a variable the template needs but no
role provides is an error here rather than an empty string on a booting
machine.

Secrets come from ``tests/fixtures/render_context.py`` and are obvious
placeholders. Nothing this script writes should ever be deployed.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from xml.etree import ElementTree

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
TEMPLATE_ROOT = REPO_ROOT / "ansible" / "templates"

sys.path.insert(0, str(REPO_ROOT / "scripts" / "lib"))
sys.path.insert(0, str(REPO_ROOT / "tests" / "fixtures"))
sys.path.insert(0, str(REPO_ROOT / "ansible" / "filter_plugins"))


def _stub_ansible() -> None:
    """The filter plugins import AnsibleFilterError; stub it if needed."""
    import types

    try:
        import ansible.errors  # noqa: F401
        return
    except ImportError:
        pass

    ansible_module = types.ModuleType("ansible")
    errors_module = types.ModuleType("ansible.errors")

    class AnsibleFilterError(Exception):
        pass

    errors_module.AnsibleFilterError = AnsibleFilterError
    ansible_module.errors = errors_module
    sys.modules["ansible"] = ansible_module
    sys.modules["ansible.errors"] = errors_module


_stub_ansible()

import forge_config  # noqa: E402
import forge_filters  # noqa: E402
import render_context  # noqa: E402

# Which templates are rendered per host, and for which OS family.
PER_HOST: dict[str, str | None] = {
    "ubuntu/user-data.j2": "linux",
    "ubuntu/meta-data.j2": "linux",
    "ubuntu/vendor-data.j2": "linux",
    "ipxe/host-ubuntu-install.ipxe.j2": "linux",
    "windows/Autounattend.xml.j2": "windows",
    "windows/specialize.cmd.j2": "windows",
    "windows/SetupComplete.cmd.j2": "windows",
    "windows/Configure-WinRM.ps1.j2": "windows",
    "windows/startnet.cmd.j2": "windows",
    "windows/winpeshl.ini.j2": "windows",
    "ipxe/host-windows-install.ipxe.j2": "windows",
    "libvirt/domain.xml.j2": None,          # every host
}

# Templates that take a report document rather than the configuration.
REPORT_TEMPLATES = {
    "report/deployment-report.md.j2",
    "report/deployment-report.html.j2",
    "report/drift-report.md.j2",
}

COLOURS = {"ok": "\033[32m", "fail": "\033[31m", "warn": "\033[33m", "reset": "\033[0m"}


def build_environment():
    from jinja2 import Environment, FileSystemLoader, StrictUndefined

    env = Environment(
        loader=FileSystemLoader(str(TEMPLATE_ROOT)),
        undefined=StrictUndefined,
        keep_trailing_newline=True,
    )
    env.filters.update(forge_filters.FilterModule().filters())
    env.filters.setdefault("to_nice_json", lambda v, **_: json.dumps(v, indent=2))
    env.filters.setdefault("to_json", lambda v, **_: json.dumps(v))
    env.filters.setdefault("basename", lambda v: str(v).rsplit("/", 1)[-1])
    env.filters.setdefault("dirname", lambda v: str(v).rsplit("/", 1)[0])
    env.filters.setdefault("regex_escape", lambda v: __import__("re").escape(str(v)))
    return env


def validate_output(name: str, output: str) -> list[str]:
    """Parse the rendered artefact the way its consumer will."""
    problems: list[str] = []

    if name.endswith((".xml.j2",)) or "Autounattend" in name:
        try:
            ElementTree.fromstring(output)
        except ElementTree.ParseError as exc:
            problems.append(f"not well-formed XML: {exc}")

    elif name.endswith("user-data.j2") or name.endswith("meta-data.j2"):
        try:
            parsed = yaml.safe_load(output)
            if name.endswith("user-data.j2") and "autoinstall" not in (parsed or {}):
                problems.append("no top-level 'autoinstall' key: Subiquity will ignore it")
        except yaml.YAMLError as exc:
            problems.append(f"not valid YAML: {exc}")

    elif name.endswith(".json.j2"):
        try:
            json.loads(output)
        except json.JSONDecodeError as exc:
            problems.append(f"not valid JSON: {exc}")

    elif ".ipxe" in name:
        if not output.lstrip().startswith("#!ipxe"):
            problems.append("does not start with #!ipxe; iPXE will refuse it")

    if not output.strip():
        problems.append("rendered empty")

    return problems


def sample_report() -> dict:
    return {
        "deployment_id": "render-check", "environment": "poc",
        "git_commit": "0" * 40, "git_branch": "main",
        "started_at": "2026-01-01T00:00:00Z", "finished_at": "2026-01-01T00:10:00Z",
        "duration_seconds": 600, "operator": "render-check", "trigger": "cli",
        "status": "success", "semaphore_task_id": "", "semaphore_task_url": "",
        "json_path": "/srv/forge-ai/reports/render-check.json",
        "hosts": [], "media": [], "versions": {}, "logs": [],
    }


def sample_drift() -> dict:
    return {
        "run_id": "render-check", "environment": "poc", "git_commit": "0" * 40,
        "git_branch": "main", "executed_at": "2026-01-01T00:00:00Z",
        "executed_by": "render-check", "mode": "check-mode", "drifted": False,
        "json_path": "/srv/forge-ai/reports/drift/render-check.json", "hosts": [],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", help="write the rendered artefacts here")
    parser.add_argument("--check", action="store_true", help="render and validate, write nothing")
    parser.add_argument("--template", help="render only this template (path relative to ansible/templates)")
    parser.add_argument("--host", help="render only for this host")
    parser.add_argument("--config", help="configuration overlay (default: config/poc.yml)")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    use_colour = sys.stderr.isatty()

    def report(status: str, message: str) -> None:
        if args.quiet and status == "ok":
            return
        prefix = f"[{status:4}]"
        if use_colour:
            prefix = f"{COLOURS[status]}{prefix}{COLOURS['reset']}"
        print(f"{prefix} {message}", file=sys.stderr)

    config = forge_config.load_config(overlay_path=args.config)
    result = forge_config.validate(config)
    if not result.ok:
        report("fail", "the configuration does not validate; templates cannot be rendered")
        for finding in result.errors:
            print(f"        {finding}", file=sys.stderr)
        return 2

    env = build_environment()
    out_dir = Path(args.out) if args.out else None
    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)

    templates = sorted(str(p.relative_to(TEMPLATE_ROOT)) for p in TEMPLATE_ROOT.rglob("*.j2"))
    if args.template:
        templates = [t for t in templates if t == args.template]
        if not templates:
            report("fail", f"no such template: {args.template}")
            return 2

    hosts = config["hosts"]
    if args.host:
        hosts = [h for h in hosts if h["name"] == args.host]
        if not hosts:
            report("fail", f"no such host: {args.host}")
            return 2

    rendered = 0
    failures = 0

    for name in templates:
        template = env.get_template(name)

        if name in REPORT_TEMPLATES:
            context = {"report": sample_report(), "drift": sample_drift()}
            targets = [(None, context)]
        elif name in PER_HOST:
            family = PER_HOST[name]
            applicable = [h for h in hosts if family is None or h["os_family"] == family]
            targets = [(h, render_context.build_context(config, host=h)) for h in applicable]
            if not targets:
                report("warn", f"{name}: no applicable host in this configuration, skipped")
                continue
        else:
            targets = [(None, render_context.build_context(config))]

        for host, context in targets:
            label = f"{name}" + (f" [{host['name']}]" if host else "")
            try:
                output = template.render(**context)
            except Exception as exc:  # noqa: BLE001 - report any render failure
                report("fail", f"{label}: {type(exc).__name__}: {exc}")
                failures += 1
                continue

            problems = validate_output(name, output)
            if problems:
                for problem in problems:
                    report("fail", f"{label}: {problem}")
                failures += 1
                continue

            rendered += 1
            report("ok", f"{label} ({len(output)} bytes)")

            if out_dir:
                suffix = Path(name).with_suffix("")   # strip .j2
                target = out_dir / (f"{host['name']}-{suffix.name}" if host else suffix.name)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(output, encoding="utf-8")

    print(file=sys.stderr)
    summary = f"{rendered} rendered, {failures} failed"
    if failures:
        report("fail", summary)
    else:
        report("ok", summary)

    if out_dir:
        report("warn", f"artefacts written to {out_dir} -- they contain FIXTURE secrets, never deploy them")

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
