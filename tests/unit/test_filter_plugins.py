"""The Jinja2 filters the templates depend on.

Each of these exists because the alternative was an unreadable inline
expression repeated across several templates. Each is also a place where
a subtle mistake produces a machine that installs perfectly and then
cannot be logged into, so they are tested directly.
"""

from __future__ import annotations

import base64

import pytest


@pytest.fixture()
def error(filters):
    import ansible.errors

    return ansible.errors.AnsibleFilterError


# ---------------------------------------------------------------------
# MAC handling -- must agree with iPXE's ${mac:hexhyp}
# ---------------------------------------------------------------------


@pytest.mark.parametrize(
    "given,expected",
    [
        ("52:54:00:25:00:21", "52-54-00-25-00-21"),
        ("52:54:00:25:00:21".upper(), "52-54-00-25-00-21"),
        ("52-54-00-25-00-21", "52-54-00-25-00-21"),
    ],
)
def test_mac_hyphen_matches_ipxe_hexhyp(filters, given, expected):
    assert filters.mac_hyphen(given) == expected


@pytest.mark.parametrize("given", ["not-a-mac", "52:54:00:25:00", "", "52:54:00:25:00:21:99"])
def test_mac_hyphen_rejects_malformed_input(filters, error, given):
    with pytest.raises(error):
        filters.mac_hyphen(given)


def test_mac_colon_normalises_either_form(filters):
    assert filters.mac_colon("52-54-00-25-00-21") == "52:54:00:25:00:21"
    assert filters.mac_colon("52:54:00:25:00:21".upper()) == "52:54:00:25:00:21"


def test_dnsmasq_tag_matches_the_ipxe_form(filters):
    """The dnsmasq set: tag and the iPXE state filename must be the same
    string, or per-host dispatch silently stops matching."""
    mac = "52:54:00:25:00:21"
    assert filters.dnsmasq_tag(mac) == filters.mac_hyphen(mac)


# ---------------------------------------------------------------------
# Network helpers
# ---------------------------------------------------------------------


@pytest.mark.parametrize(
    "cidr,netmask,prefix",
    [
        ("192.168.250.0/24", "255.255.255.0", 24),
        ("10.0.0.0/8", "255.0.0.0", 8),
        ("172.16.0.0/12", "255.240.0.0", 12),
        ("192.168.1.0/30", "255.255.255.252", 30),
    ],
)
def test_netmask_and_prefix_from_cidr(filters, cidr, netmask, prefix):
    assert filters.netmask_from_cidr(cidr) == netmask
    assert filters.prefix_from_cidr(cidr) == prefix


def test_cidr_helpers_reject_a_host_bit_set(filters, error):
    """192.168.250.5/24 is a host address, not a network."""
    with pytest.raises(error):
        filters.netmask_from_cidr("192.168.250.5/24")


def test_ip_in_cidr(filters):
    assert filters.ip_in_cidr("192.168.250.21", "192.168.250.0/24")
    assert not filters.ip_in_cidr("192.168.251.21", "192.168.250.0/24")


def test_ip_in_cidr_rejects_nonsense(filters, error):
    with pytest.raises(error):
        filters.ip_in_cidr("not-an-ip", "192.168.250.0/24")


# ---------------------------------------------------------------------
# Windows password encoding
# ---------------------------------------------------------------------


def test_win_unattend_password_round_trips(filters):
    """Windows expects Base64(UTF-16LE(password + field-name)). Getting
    the field name wrong leaves the account with NO password, and the
    host installs perfectly but rejects every login."""
    encoded = filters.win_unattend_password("Pa55w0rd!Secure", "AdministratorPassword")
    decoded = base64.b64decode(encoded).decode("utf-16-le")

    assert decoded == "Pa55w0rd!SecureAdministratorPassword"


def test_win_unattend_password_supports_the_user_password_field(filters):
    encoded = filters.win_unattend_password("Pa55w0rd!", "Password")
    assert base64.b64decode(encoded).decode("utf-16-le") == "Pa55w0rd!Password"


def test_win_unattend_password_rejects_an_unknown_field(filters, error):
    """Windows only appends those two literal strings; anything else
    produces a password nobody can guess, including the operator."""
    with pytest.raises(error):
        filters.win_unattend_password("secret", "SomeOtherField")


def test_win_unattend_password_rejects_undefined(filters, error):
    with pytest.raises(error):
        filters.win_unattend_password(None)


def test_win_unattend_password_handles_non_ascii(filters):
    encoded = filters.win_unattend_password("pässwörd-ü", "Password")
    assert base64.b64decode(encoded).decode("utf-16-le") == "pässwörd-üPassword"


# ---------------------------------------------------------------------
# iPXE escaping
# ---------------------------------------------------------------------


def test_ipxe_escape_doubles_the_dollar(filters):
    """iPXE expands ${...} inside scripts, so a literal $ must be doubled
    or the value silently becomes an empty variable reference."""
    assert filters.ipxe_escape("cost$5") == "cost$$5"
    assert filters.ipxe_escape("${net0/mac}") == "$${net0/mac}"


def test_ipxe_escape_rejects_newlines(filters, error):
    """A newline would end the iPXE command and let the rest of the value
    be interpreted as a new one."""
    with pytest.raises(error):
        filters.ipxe_escape("first\nsecond")


# ---------------------------------------------------------------------
# Lookup helpers
# ---------------------------------------------------------------------


def test_host_lookup_by_name_and_mac(filters, base_config):
    hosts = base_config["hosts"]

    assert filters.host_by_name(hosts, "poc-ubuntu-01")["os_family"] == "linux"
    assert filters.host_by_mac(hosts, "52-54-00-25-00-21")["name"] == "poc-ubuntu-01"
    assert filters.host_by_mac(hosts, "52:54:00:25:00:21".upper())["name"] == "poc-ubuntu-01"


def test_host_lookup_failures_are_explicit(filters, error, base_config):
    with pytest.raises(error):
        filters.host_by_name(base_config["hosts"], "no-such-host")
    with pytest.raises(error):
        filters.host_by_mac(base_config["hosts"], "aa:bb:cc:dd:ee:ff")


# ---------------------------------------------------------------------
# Reporting helpers
# ---------------------------------------------------------------------


@pytest.mark.parametrize(
    "seconds,expected",
    [(0, "0s"), (45, "45s"), (60, "1m 0s"), (125, "2m 5s"), (3600, "1h 0m 0s"), (3725, "1h 2m 5s")],
)
def test_duration_human(filters, seconds, expected):
    assert filters.duration_human(seconds) == expected


def test_duration_human_rejects_nonsense(filters, error):
    with pytest.raises(error):
        filters.duration_human("soon")
    with pytest.raises(error):
        filters.duration_human(-1)


def test_redact_keeps_a_recognisable_prefix(filters):
    """Enough to correlate a token with a log line, not enough to use."""
    assert filters.redact("supersecrettoken") == "supe************"
    assert filters.redact("abc") == "***"
    assert "secret" not in filters.redact("mysecretvalue", keep=2)


def test_sha256_of_is_stable(filters):
    assert filters.sha256_of("forge-ai") == filters.sha256_of("forge-ai")
    assert filters.sha256_of("a") != filters.sha256_of("b")
    assert len(filters.sha256_of("x")) == 64


# ---------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------


def test_every_filter_is_registered(filters):
    """A filter that exists but is not in FilterModule().filters() is
    invisible to Ansible, and the template using it fails at render time
    on the host rather than here."""
    registered = filters.FilterModule().filters()

    expected = {
        "mac_hyphen", "mac_colon", "netmask_from_cidr", "prefix_from_cidr",
        "ip_in_cidr", "win_unattend_password", "ipxe_escape", "dnsmasq_tag",
        "sha256_of", "host_by_name", "host_by_mac", "duration_human", "redact",
    }

    assert expected <= set(registered)
    for name, function in registered.items():
        assert callable(function), name
