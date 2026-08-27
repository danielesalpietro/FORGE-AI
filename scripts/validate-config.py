#!/usr/bin/env python3
"""Validate the FORGE-AI configuration and optionally emit it as JSON.

Exit codes
    0  configuration is valid (warnings may still be present)
    1  configuration has at least one error
    2  the configuration could not be loaded at all

Examples
    scripts/validate-config.py                       # human-readable report
    scripts/validate-config.py --strict              # warnings become errors
    scripts/validate-config.py --check-media         # also stat() the ISOs
    scripts/validate-config.py --json                # merged config to stdout
    scripts/validate-config.py --format github       # GitHub Actions annotations
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

import forge_config  # noqa: E402  (path bootstrap above)

COLOURS = {
    "error": "\033[31m",
    "warning": "\033[33m",
    "info": "\033[36m",
    "reset": "\033[0m",
}


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--defaults", default=str(forge_config.DEFAULTS_PATH), help="path to config/defaults.yml")
    parser.add_argument(
        "--config",
        default=None,
        help="operator overlay (default: config/poc.yml, falling back to config/poc.example.yml)",
    )
    parser.add_argument("--schema", default=str(forge_config.SCHEMA_PATH), help="path to the JSON Schema")
    parser.add_argument("--strict", action="store_true", help="treat warnings as errors")
    parser.add_argument("--check-media", action="store_true", help="verify that the configured ISO files exist and are readable")
    parser.add_argument("--json", action="store_true", help="print the merged configuration as JSON on success")
    parser.add_argument("--quiet", action="store_true", help="only print findings, no summary")
    parser.add_argument(
        "--format",
        choices=["text", "github"],
        default="text",
        help="'github' emits ::error/::warning workflow commands",
    )
    return parser.parse_args(argv)


def emit(finding: forge_config.Finding, fmt: str, use_colour: bool) -> None:
    if fmt == "github":
        level = "error" if finding.severity == "error" else "warning" if finding.severity == "warning" else "notice"
        message = finding.message.replace("\n", " ")
        print(f"::{level} title=config {finding.path}::{message}")
        return
    if use_colour:
        colour = COLOURS.get(finding.severity, "")
        print(f"{colour}[{finding.severity.upper():7}]{COLOURS['reset']} {finding.path}: {finding.message}", file=sys.stderr)
    else:
        print(str(finding), file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    use_colour = sys.stderr.isatty() and args.format == "text"

    try:
        config = forge_config.load_config(args.defaults, args.config)
    except (FileNotFoundError, ValueError) as exc:
        print(f"configuration could not be loaded: {exc}", file=sys.stderr)
        return 2

    result = forge_config.validate(config, check_media=args.check_media, schema_path=args.schema)

    for finding in result.findings:
        emit(finding, args.format, use_colour)

    failed = bool(result.errors) or (args.strict and bool(result.warnings))

    if not args.quiet and args.format == "text":
        source = config.get("_meta", {}).get("overlay_path") or "<defaults only>"
        summary = (
            f"config: {source}\n"
            f"hosts: {len(config.get('hosts') or [])}  "
            f"errors: {len(result.errors)}  warnings: {len(result.warnings)}"
        )
        print(summary, file=sys.stderr)
        print("RESULT: " + ("FAIL" if failed else "PASS"), file=sys.stderr)

    if failed:
        return 1

    if args.json:
        json.dump(forge_config.strip_meta(config), sys.stdout, indent=2, sort_keys=False)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
