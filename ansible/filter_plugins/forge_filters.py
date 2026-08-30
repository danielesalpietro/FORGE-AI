"""FORGE-AI Jinja2 filters shared by playbooks and templates.

Ansible discovers this module through ``filter_plugins`` in
``ansible/ansible.cfg``. Each filter exists because the alternative was
an unreadable inline expression repeated across several templates.

Unit tests: ``tests/unit/test_filter_plugins.py``.
"""

from __future__ import annotations

import base64
import hashlib
import ipaddress
import re

from ansible.errors import AnsibleFilterError

MAC_RE = re.compile(r"^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$")


def mac_hyphen(mac: str) -> str:
    """``52:54:00:25:00:21`` -> ``52-54-00-25-00-21``.

    Matches iPXE's ``${mac:hexhyp}`` expansion, which is how per-host
    boot scripts and state files are named.
    """
    if not MAC_RE.match(str(mac)):
        raise AnsibleFilterError(f"mac_hyphen: {mac!r} is not a MAC address")
    return str(mac).lower().replace(":", "-")


def mac_colon(mac: str) -> str:
    """Normalise any MAC spelling to lower-case colon form."""
    if not MAC_RE.match(str(mac)):
        raise AnsibleFilterError(f"mac_colon: {mac!r} is not a MAC address")
    return str(mac).lower().replace("-", ":")


def netmask_from_cidr(cidr: str) -> str:
    """``192.168.250.0/24`` -> ``255.255.255.0``."""
    try:
        return str(ipaddress.ip_network(cidr, strict=True).netmask)
    except ValueError as exc:
        raise AnsibleFilterError(f"netmask_from_cidr: {exc}") from exc


def prefix_from_cidr(cidr: str) -> int:
    try:
        return int(ipaddress.ip_network(cidr, strict=True).prefixlen)
    except ValueError as exc:
        raise AnsibleFilterError(f"prefix_from_cidr: {exc}") from exc


def ip_in_cidr(address: str, cidr: str) -> bool:
    try:
        return ipaddress.ip_address(address) in ipaddress.ip_network(cidr, strict=True)
    except ValueError as exc:
        raise AnsibleFilterError(f"ip_in_cidr: {exc}") from exc


def win_unattend_password(password: str, field: str = "AdministratorPassword") -> str:
    """Encode a password the way Windows Setup expects.

    ``<AdministratorPassword><Value>`` with ``PlainText=false`` holds
    Base64 of UTF-16LE(password + field-name). Windows calls this
    "encrypted"; it is reversible by anyone with the file, so treat it
    as obfuscation only. Documented in docs/SECURITY.md.

    ``field`` must be the name of the XML element the value lands in --
    ``AdministratorPassword`` or ``Password`` -- because Windows
    appends exactly that string before encoding.
    """
    if password is None:
        raise AnsibleFilterError("win_unattend_password: password is undefined")
    if field not in {"AdministratorPassword", "Password"}:
        raise AnsibleFilterError(
            f"win_unattend_password: unsupported field {field!r}; "
            "Windows only accepts 'AdministratorPassword' or 'Password'"
        )
    return base64.b64encode(f"{password}{field}".encode("utf-16-le")).decode("ascii")


def ipxe_escape(value: str) -> str:
    """Escape a value for safe interpolation into an iPXE script.

    iPXE expands ``${...}`` inside scripts; a literal ``$`` therefore has
    to be doubled. Newlines would terminate the command.
    """
    text = str(value)
    if "\n" in text or "\r" in text:
        raise AnsibleFilterError("ipxe_escape: value must not contain newlines")
    return text.replace("$", "$$")


def dnsmasq_tag(mac: str) -> str:
    """dnsmasq ``set:`` tag for a host, derived from its MAC."""
    return mac_hyphen(mac)


def sha256_of(text: str) -> str:
    return hashlib.sha256(str(text).encode("utf-8")).hexdigest()


def host_by_name(hosts: list, name: str) -> dict:
    for host in hosts or []:
        if host.get("name") == name:
            return host
    raise AnsibleFilterError(f"host_by_name: no host named {name!r}")


def host_by_mac(hosts: list, mac: str) -> dict:
    wanted = mac_colon(mac)
    for host in hosts or []:
        if mac_colon(host.get("mac_address", "00:00:00:00:00:00")) == wanted:
            return host
    raise AnsibleFilterError(f"host_by_mac: no host with MAC {mac!r}")


def duration_human(seconds) -> str:
    """``3725`` -> ``1h 2m 5s`` -- used by the deployment report."""
    try:
        total = int(seconds)
    except (TypeError, ValueError) as exc:
        raise AnsibleFilterError(f"duration_human: {seconds!r} is not a number") from exc
    if total < 0:
        raise AnsibleFilterError("duration_human: duration cannot be negative")
    hours, remainder = divmod(total, 3600)
    minutes, secs = divmod(remainder, 60)
    parts = []
    if hours:
        parts.append(f"{hours}h")
    if minutes or hours:
        parts.append(f"{minutes}m")
    parts.append(f"{secs}s")
    return " ".join(parts)


def redact(value: str, keep: int = 4) -> str:
    """Render a secret safe for a log line."""
    text = str(value)
    if len(text) <= keep:
        return "*" * len(text)
    return text[:keep] + "*" * (len(text) - keep)


class FilterModule:
    """Ansible entry point."""

    def filters(self):
        return {
            "mac_hyphen": mac_hyphen,
            "mac_colon": mac_colon,
            "netmask_from_cidr": netmask_from_cidr,
            "prefix_from_cidr": prefix_from_cidr,
            "ip_in_cidr": ip_in_cidr,
            "win_unattend_password": win_unattend_password,
            "ipxe_escape": ipxe_escape,
            "dnsmasq_tag": dnsmasq_tag,
            "sha256_of": sha256_of,
            "host_by_name": host_by_name,
            "host_by_mac": host_by_mac,
            "duration_human": duration_human,
            "redact": redact,
        }
