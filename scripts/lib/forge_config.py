"""FORGE-AI configuration loader and validator.

Single source of truth for reading ``config/defaults.yml`` +
``config/poc.yml``, merging them, applying host defaults and validating
the result.

Used by:
  * ``scripts/validate-config.py``      (make validate, GitHub Actions)
  * ``tests/unit/``                     (pytest)
  * ``scripts/render-templates.py``     (offline Jinja2 render checks)
  * ``ansible/playbooks/site.yml``      (via the ``forge_config`` lookup)

Validation is deliberately split in two:

  1. **Structural** -- JSON Schema (``config/schema/poc.schema.json``).
     Types, enums, patterns, ranges.
  2. **Semantic**   -- things JSON Schema cannot express: duplicate MAC
     and IP addresses, CIDR membership, DHCP pool overlap, media
     availability, plaintext secret hygiene.

Both produce :class:`Finding` objects so callers can decide whether a
warning is fatal in their context.
"""

from __future__ import annotations

import copy
import ipaddress
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULTS_PATH = REPO_ROOT / "config" / "defaults.yml"
OVERLAY_PATH = REPO_ROOT / "config" / "poc.yml"
EXAMPLE_OVERLAY_PATH = REPO_ROOT / "config" / "poc.example.yml"
SCHEMA_PATH = REPO_ROOT / "config" / "schema" / "poc.schema.json"

# Keys whose value must never be a real secret inside version control.
SECRET_KEY_PATTERN = re.compile(
    r"(password|passwd|secret|token|api_key|apikey|private_key|product_key|"
    r"credential|passphrase)",
    re.IGNORECASE,
)

# Values that are obviously placeholders rather than live secrets.
PLACEHOLDER_PATTERN = re.compile(
    r"^\s*(|changeme|change-me|CHANGEME|placeholder|<[^>]+>|\$\{[^}]+\}|"
    r"REPLACE_ME|xxx+|\.\.\.)\s*$",
    re.IGNORECASE,
)

# Configuration keys that merely *mention* a secret-ish word but hold
# policy, not credentials. Matched against the full dotted path.
SECRET_KEY_ALLOWLIST = {
    "security.ssh_password_authentication",   # "no" / "yes" policy switch
    "security.ssh_permit_root_login",
    "safety.destroy_confirmation_token",      # a literal confirmation word
    "media.windows.product_key",              # schema already forces empty
    "gitops.gitea_admin_user",
}

SEVERITY_ORDER = {"error": 2, "warning": 1, "info": 0}


@dataclass(frozen=True)
class Finding:
    """A single validation result."""

    severity: str  # "error" | "warning" | "info"
    path: str      # dotted path into the configuration
    message: str

    def __str__(self) -> str:  # pragma: no cover - formatting only
        return f"[{self.severity.upper():7}] {self.path}: {self.message}"


@dataclass
class ValidationResult:
    findings: list[Finding] = field(default_factory=list)

    def add(self, severity: str, path: str, message: str) -> None:
        self.findings.append(Finding(severity, path, message))

    @property
    def errors(self) -> list[Finding]:
        return [f for f in self.findings if f.severity == "error"]

    @property
    def warnings(self) -> list[Finding]:
        return [f for f in self.findings if f.severity == "warning"]

    @property
    def ok(self) -> bool:
        return not self.errors

    def extend(self, other: "ValidationResult") -> None:
        self.findings.extend(other.findings)


# ---------------------------------------------------------------------
# Loading and merging
# ---------------------------------------------------------------------


def deep_merge(base: dict, overlay: dict) -> dict:
    """Recursively merge ``overlay`` into ``base`` and return a new dict.

    Lists are replaced wholesale, never concatenated: an operator who
    sets ``dns_servers`` expects exactly that list, not the union with
    the defaults.
    """
    result = copy.deepcopy(base)
    for key, value in (overlay or {}).items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result


def load_yaml(path: os.PathLike | str) -> dict:
    path = Path(path)
    if not path.is_file():
        raise FileNotFoundError(f"configuration file not found: {path}")
    with path.open("r", encoding="utf-8") as handle:
        data = yaml.safe_load(handle)
    if data is None:
        return {}
    if not isinstance(data, dict):
        raise ValueError(f"{path}: expected a YAML mapping at the top level")
    return data


def apply_host_defaults(config: dict) -> dict:
    """Fill every host entry with the values from ``defaults:``."""
    config = copy.deepcopy(config)
    host_defaults = config.get("defaults", {}) or {}
    inheritable = (
        "firmware",
        "machine",
        "cpu_mode",
        "disk_bus",
        "network_model",
        "vcpu",
        "memory_mb",
        "disk_gb",
    )
    for host in config.get("hosts", []) or []:
        for key in inheritable:
            if key not in host and key in host_defaults:
                host[key] = host_defaults[key]
    return config


def load_config(
    defaults_path: os.PathLike | str = DEFAULTS_PATH,
    overlay_path: os.PathLike | str | None = None,
    *,
    allow_missing_overlay: bool = True,
) -> dict:
    """Load defaults, merge the operator overlay, apply host defaults.

    When ``overlay_path`` is ``None`` the loader prefers
    ``config/poc.yml`` and transparently falls back to
    ``config/poc.example.yml``. That fallback is what lets CI validate
    the repository without an operator-owned (git-ignored) file.
    """
    base = load_yaml(defaults_path)

    if overlay_path is None:
        overlay_path = OVERLAY_PATH if Path(OVERLAY_PATH).is_file() else EXAMPLE_OVERLAY_PATH

    overlay_file = Path(overlay_path)
    if overlay_file.is_file():
        overlay = load_yaml(overlay_file)
    elif allow_missing_overlay:
        overlay = {}
    else:
        raise FileNotFoundError(f"configuration overlay not found: {overlay_file}")

    merged = deep_merge(base, overlay)
    merged["_meta"] = {
        "defaults_path": str(defaults_path),
        "overlay_path": str(overlay_file) if overlay_file.is_file() else None,
    }
    return apply_host_defaults(merged)


def strip_meta(config: dict) -> dict:
    """Return a copy without the loader bookkeeping key."""
    clean = copy.deepcopy(config)
    clean.pop("_meta", None)
    return clean


# ---------------------------------------------------------------------
# Structural validation
# ---------------------------------------------------------------------


def validate_schema(config: dict, schema_path: os.PathLike | str = SCHEMA_PATH) -> ValidationResult:
    import json

    import jsonschema

    result = ValidationResult()
    with Path(schema_path).open("r", encoding="utf-8") as handle:
        schema = json.load(handle)

    validator_cls = jsonschema.validators.validator_for(schema)
    validator_cls.check_schema(schema)
    validator = validator_cls(schema)

    for error in sorted(validator.iter_errors(strip_meta(config)), key=lambda e: list(e.path)):
        dotted = ".".join(str(p) for p in error.absolute_path) or "<root>"
        result.add("error", dotted, error.message)
    return result


# ---------------------------------------------------------------------
# Semantic validation
# ---------------------------------------------------------------------


def _iter_scalars(node: Any, prefix: str = "") -> Iterable[tuple[str, Any]]:
    if isinstance(node, dict):
        for key, value in node.items():
            yield from _iter_scalars(value, f"{prefix}.{key}" if prefix else str(key))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from _iter_scalars(value, f"{prefix}[{index}]")
    else:
        yield prefix, node


def _is_locally_administered_unicast(mac: str) -> bool:
    first_octet = int(mac.split(":")[0], 16)
    unicast = (first_octet & 0b1) == 0
    local = (first_octet & 0b10) != 0
    return unicast and local


def validate_semantics(config: dict, *, check_media: bool = False) -> ValidationResult:
    """Rules JSON Schema cannot express."""
    result = ValidationResult()
    net = config.get("provisioning_network", {}) or {}
    hosts = config.get("hosts", []) or []

    # -- network -------------------------------------------------------
    network = None
    try:
        network = ipaddress.ip_network(net["cidr"], strict=True)
    except KeyError:
        result.add("error", "provisioning_network.cidr", "missing")
    except ValueError as exc:
        result.add("error", "provisioning_network.cidr", f"invalid network: {exc}")

    def _addr(path: str, value: str | None) -> ipaddress.IPv4Address | None:
        if value is None:
            return None
        try:
            return ipaddress.ip_address(value)
        except ValueError as exc:
            result.add("error", path, f"invalid IPv4 address: {exc}")
            return None

    gateway = _addr("provisioning_network.gateway", net.get("gateway"))
    dhcp_start = _addr("provisioning_network.dhcp_start", net.get("dhcp_start"))
    dhcp_end = _addr("provisioning_network.dhcp_end", net.get("dhcp_end"))

    if network is not None:
        expected_netmask = str(network.netmask)
        if net.get("netmask") and net["netmask"] != expected_netmask:
            result.add(
                "error",
                "provisioning_network.netmask",
                f"{net['netmask']} does not match {net['cidr']} (expected {expected_netmask})",
            )
        for label, addr in (("gateway", gateway), ("dhcp_start", dhcp_start), ("dhcp_end", dhcp_end)):
            if addr is not None and addr not in network:
                result.add(
                    "error",
                    f"provisioning_network.{label}",
                    f"{addr} is outside {network}",
                )
        if network.prefixlen > 29:
            result.add(
                "error",
                "provisioning_network.cidr",
                f"{network} is too small to host a DHCP pool and reservations",
            )

    if dhcp_start is not None and dhcp_end is not None and dhcp_start > dhcp_end:
        result.add(
            "error",
            "provisioning_network.dhcp_start",
            f"DHCP range start {dhcp_start} is above end {dhcp_end}",
        )

    control_address = (config.get("control_plane", {}) or {}).get("address")
    if control_address and gateway is not None and control_address != str(gateway):
        result.add(
            "error",
            "control_plane.address",
            f"{control_address} must equal provisioning_network.gateway ({gateway}); "
            "the boot HTTP/TFTP services are bound to the libvirt bridge address",
        )

    # -- hosts ---------------------------------------------------------
    seen_names: dict[str, int] = {}
    seen_ips: dict[str, int] = {}
    seen_macs: dict[str, int] = {}

    for index, host in enumerate(hosts):
        path = f"hosts[{index}]"
        name = host.get("name")
        ip_raw = host.get("ip_address")
        mac_raw = host.get("mac_address")

        if name is not None:
            if name in seen_names:
                result.add("error", f"{path}.name", f"duplicate host name '{name}' (first seen at hosts[{seen_names[name]}])")
            else:
                seen_names[name] = index

        if ip_raw is not None:
            if ip_raw in seen_ips:
                result.add("error", f"{path}.ip_address", f"duplicate IP address {ip_raw} (first seen at hosts[{seen_ips[ip_raw]}])")
            else:
                seen_ips[ip_raw] = index
            addr = _addr(f"{path}.ip_address", ip_raw)
            if addr is not None:
                if network is not None and addr not in network:
                    result.add("error", f"{path}.ip_address", f"{addr} is outside the provisioning network {network}")
                if network is not None and addr == network.network_address:
                    result.add("error", f"{path}.ip_address", f"{addr} is the network address")
                if network is not None and addr == network.broadcast_address:
                    result.add("error", f"{path}.ip_address", f"{addr} is the broadcast address")
                if gateway is not None and addr == gateway:
                    result.add("error", f"{path}.ip_address", f"{addr} collides with the gateway/control-plane address")
                if dhcp_start is not None and dhcp_end is not None and dhcp_start <= addr <= dhcp_end:
                    result.add(
                        "error",
                        f"{path}.ip_address",
                        f"{addr} falls inside the dynamic DHCP pool {dhcp_start}-{dhcp_end}; "
                        "static reservations must live outside the pool to stay collision-free",
                    )

        if mac_raw is not None:
            normalised = str(mac_raw).lower()
            if normalised != str(mac_raw):
                result.add("warning", f"{path}.mac_address", "MAC addresses should be lower-case for dnsmasq and iPXE matching")
            if normalised in seen_macs:
                result.add("error", f"{path}.mac_address", f"duplicate MAC address {mac_raw} (first seen at hosts[{seen_macs[normalised]}])")
            else:
                seen_macs[normalised] = index
            if re.fullmatch(r"([0-9a-f]{2}:){5}[0-9a-f]{2}", normalised):
                if not _is_locally_administered_unicast(normalised):
                    result.add(
                        "error",
                        f"{path}.mac_address",
                        f"{mac_raw} is not a locally administered unicast address; "
                        "use the 52:54:00 QEMU prefix to stay deterministic and collision-free",
                    )

        # Resource sanity beyond the schema ranges.
        if host.get("os_family") == "windows":
            if (host.get("memory_mb") or 0) < 4096:
                result.add("warning", f"{path}.memory_mb", "Windows Server Setup is unreliable below 4096 MB")
            if (host.get("disk_gb") or 0) < 64:
                result.add("warning", f"{path}.disk_gb", "Windows Server needs >= 64 GB for install plus updates")
        if (host.get("memory_mb") or 0) % 128 != 0:
            result.add("warning", f"{path}.memory_mb", "memory should be a multiple of 128 MB")

    if not hosts:
        result.add("error", "hosts", "at least one host must be defined")

    # -- media ---------------------------------------------------------
    media = config.get("media", {}) or {}
    ubuntu_media = media.get("ubuntu", {}) or {}
    windows_media = media.get("windows", {}) or {}
    has_linux = any(h.get("os_family") == "linux" for h in hosts)
    has_windows = any(h.get("os_family") == "windows" for h in hosts)

    if has_windows:
        if not windows_media.get("iso_path"):
            result.add(
                "warning",
                "media.windows.iso_path",
                "empty: Windows media is operator-supplied. The Windows provisioning "
                "playbook refuses to run until this points at a readable ISO "
                "(see docs/WINDOWS-PROVISIONING.md). Ubuntu-only runs are unaffected.",
            )
        if not windows_media.get("image_name") and not windows_media.get("image_index"):
            result.add(
                "error",
                "media.windows.image_name",
                "either image_name or a non-zero image_index must select the edition inside "
                "install.wim; index 1 is not a safe assumption",
            )

    if check_media:
        if has_linux and ubuntu_media.get("iso_path") and not Path(ubuntu_media["iso_path"]).is_file():
            result.add("error", "media.ubuntu.iso_path", f"file not found: {ubuntu_media['iso_path']} (run 'make prepare-media')")
        if has_windows:
            iso = windows_media.get("iso_path")
            if not iso:
                result.add("error", "media.windows.iso_path", "required for the Windows target but not configured")
            elif not Path(iso).is_file():
                result.add("error", "media.windows.iso_path", f"file not found: {iso}")
            elif not os.access(iso, os.R_OK):
                result.add("error", "media.windows.iso_path", f"not readable by the current user: {iso}")

    # -- storage layout ------------------------------------------------
    storage = config.get("storage", {}) or {}
    artifacts = storage.get("artifacts_dir")
    if artifacts:
        for key in ("http_root", "tftp_root", "iso_dir", "state_dir", "log_dir", "report_dir"):
            value = storage.get(key)
            if value and not str(value).startswith(str(artifacts).rstrip("/") + "/"):
                result.add(
                    "warning",
                    f"storage.{key}",
                    f"{value} is outside artifacts_dir ({artifacts}); teardown only cleans artifacts_dir",
                )

    # -- secret hygiene -------------------------------------------------
    for dotted, value in _iter_scalars(strip_meta(config)):
        leaf = dotted.split(".")[-1].split("[")[0]
        if not SECRET_KEY_PATTERN.search(leaf):
            continue
        if isinstance(value, bool) or value is None:
            continue
        text = str(value)
        if PLACEHOLDER_PATTERN.match(text):
            continue
        # ssh_authorized_keys holds *public* keys - explicitly allowed.
        if "ssh_authorized_keys" in dotted:
            continue
        # Policy switches whose name merely contains a secret-ish word.
        if re.sub(r"\[\d+\]", "", dotted) in SECRET_KEY_ALLOWLIST:
            continue
        result.add(
            "error",
            dotted,
            "looks like a live secret committed to configuration. Move it to Ansible Vault "
            "or the Semaphore Key Store (see docs/SECURITY.md).",
        )

    # -- safety --------------------------------------------------------
    safety = config.get("safety", {}) or {}
    token = safety.get("destroy_confirmation_token", "")
    if token and token.lower() in {"yes", "true", "ok", "confirm"}:
        result.add("error", "safety.destroy_confirmation_token", "too easy to type by accident")

    return result


def validate(config: dict, *, check_media: bool = False, schema_path: os.PathLike | str = SCHEMA_PATH) -> ValidationResult:
    """Run structural then semantic validation."""
    result = ValidationResult()
    result.extend(validate_schema(config, schema_path))
    result.extend(validate_semantics(config, check_media=check_media))
    return result


# ---------------------------------------------------------------------
# Derived views used by templates and Ansible
# ---------------------------------------------------------------------


def host_by_name(config: dict, name: str) -> dict:
    for host in config.get("hosts", []) or []:
        if host.get("name") == name:
            return host
    raise KeyError(f"no host named {name!r} in configuration")


def host_by_mac(config: dict, mac: str) -> dict:
    wanted = mac.lower().replace("-", ":")
    for host in config.get("hosts", []) or []:
        if str(host.get("mac_address", "")).lower() == wanted:
            return host
    raise KeyError(f"no host with MAC {mac!r} in configuration")


def mac_to_ipxe_filename(mac: str) -> str:
    """iPXE ``${mac:hexhyp}`` form used for per-host boot scripts.

    ``52:54:00:25:00:21`` -> ``52-54-00-25-00-21``
    """
    return mac.lower().replace(":", "-")


def boot_base_url(config: dict) -> str:
    cp = config.get("control_plane", {}) or {}
    return f"http://{cp.get('address')}:{cp.get('boot_http_port', 8080)}"


if __name__ == "__main__":  # pragma: no cover - convenience entry point
    cfg = load_config()
    outcome = validate(cfg)
    for finding in outcome.findings:
        print(finding, file=sys.stderr)
    sys.exit(0 if outcome.ok else 1)
