"""Configuration validation: schema plus the semantic rules.

These are the checks that stop a bad desired state from ever reaching a
machine. They run in CI on every pull request and locally via
``make validate``.
"""

from __future__ import annotations

import copy

import pytest


# ---------------------------------------------------------------------
# The shipped configuration must be valid
# ---------------------------------------------------------------------


def test_shipped_example_configuration_is_valid(forge_config_module, base_config):
    result = forge_config_module.validate(base_config)
    assert result.ok, "config/poc.example.yml must validate: " + "; ".join(
        f"{f.path}: {f.message}" for f in result.errors
    )


def test_defaults_alone_have_no_structural_defects(forge_config_module, tmp_path):
    """config/defaults.yml is the baseline every deployment inherits.

    On its own it has an empty `hosts` list, which the schema rejects by
    design -- a configuration with no targets is not deployable. The
    point of this test is that `hosts` is the ONLY thing wrong with it:
    a typo or a bad enum anywhere else in defaults.yml would break every
    environment, so it must be caught here rather than in whichever
    overlay happens to touch that key first.
    """
    # An explicitly absent overlay: passing None would make the loader
    # fall back to config/poc.yml, which is exactly what this test needs
    # to avoid.
    config = forge_config_module.load_config(
        forge_config_module.DEFAULTS_PATH,
        overlay_path=tmp_path / "no-such-overlay.yml",
        allow_missing_overlay=True,
    )

    errors = forge_config_module.validate_schema(config).errors
    unrelated = [f for f in errors if not f.path.startswith("hosts")]

    assert unrelated == [], [str(f) for f in unrelated]
    assert errors, "an empty hosts list must still be rejected"


def test_example_defines_both_target_operating_systems(base_config):
    families = {host["os_family"] for host in base_config["hosts"]}
    assert families == {"linux", "windows"}, (
        "the PoC is specified as one Ubuntu and one Windows target"
    )


def test_host_defaults_are_applied(base_config):
    for host in base_config["hosts"]:
        for key in ("firmware", "machine", "cpu_mode", "disk_bus", "network_model"):
            assert key in host, f"{host['name']} did not inherit {key} from defaults:"


# ---------------------------------------------------------------------
# Duplicate detection -- the requirement calls these out by name
# ---------------------------------------------------------------------


def test_duplicate_ip_addresses_are_rejected(forge_config_module, base_config):
    config = copy.deepcopy(base_config)
    config["hosts"][1]["ip_address"] = config["hosts"][0]["ip_address"]

    result = forge_config_module.validate_semantics(config)

    assert not result.ok
    assert any(
        "duplicate IP address" in f.message for f in result.errors
    ), [str(f) for f in result.errors]


def test_duplicate_mac_addresses_are_rejected(forge_config_module, base_config):
    config = copy.deepcopy(base_config)
    config["hosts"][1]["mac_address"] = config["hosts"][0]["mac_address"]

    result = forge_config_module.validate_semantics(config)

    assert not result.ok
    assert any("duplicate MAC address" in f.message for f in result.errors)


def test_duplicate_mac_detection_is_case_insensitive(forge_config_module, base_config):
    """52:54:00:25:00:21 and 52:54:00:25:00:21 differing only in case is
    still one address as far as dnsmasq and iPXE are concerned."""
    config = copy.deepcopy(base_config)
    config["hosts"][1]["mac_address"] = config["hosts"][0]["mac_address"].upper()

    result = forge_config_module.validate_semantics(config)

    assert any("duplicate MAC address" in f.message for f in result.errors)


def test_duplicate_host_names_are_rejected(forge_config_module, base_config):
    config = copy.deepcopy(base_config)
    config["hosts"][1]["name"] = config["hosts"][0]["name"]

    result = forge_config_module.validate_semantics(config)

    assert any("duplicate host name" in f.message for f in result.errors)


# ---------------------------------------------------------------------
# CIDR membership and DHCP pool overlap
# ---------------------------------------------------------------------


def test_host_outside_the_provisioning_network_is_rejected(forge_config_module, base_config):
    config = copy.deepcopy(base_config)
    config["hosts"][0]["ip_address"] = "10.99.99.99"

    result = forge_config_module.validate_semantics(config)

    assert any("outside the provisioning network" in f.message for f in result.errors)


def test_host_inside_the_dhcp_pool_is_rejected(forge_config_module, base_config):
    """A static reservation inside the dynamic pool eventually collides."""
    config = copy.deepcopy(base_config)
    config["hosts"][0]["ip_address"] = config["provisioning_network"]["dhcp_start"]

    result = forge_config_module.validate_semantics(config)

    assert any("dynamic DHCP pool" in f.message for f in result.errors)


def test_host_colliding_with_the_gateway_is_rejected(forge_config_module, base_config):
    config = copy.deepcopy(base_config)
    config["hosts"][0]["ip_address"] = config["provisioning_network"]["gateway"]

    result = forge_config_module.validate_semantics(config)

    assert any("collides with the gateway" in f.message for f in result.errors)


def test_gateway_outside_its_own_network_is_rejected(forge_config_module, base_config):
    config = copy.deepcopy(base_config)
    config["provisioning_network"]["gateway"] = "10.0.0.1"
    config["control_plane"]["address"] = "10.0.0.1"

    result = forge_config_module.validate_semantics(config)

    assert any("is outside" in f.message for f in result.errors)


def test_netmask_inconsistent_with_the_cidr_is_rejected(forge_config_module, base_config):
    config = copy.deepcopy(base_config)
    config["provisioning_network"]["netmask"] = "255.255.0.0"

    result = forge_config_module.validate_semantics(config)

    assert any("does not match" in f.message for f in result.errors)


def test_inverted_dhcp_range_is_rejected(forge_config_module, base_config):
    config = copy.deepcopy(base_config)
    network = config["provisioning_network"]
    network["dhcp_start"], network["dhcp_end"] = network["dhcp_end"], network["dhcp_start"]

    result = forge_config_module.validate_semantics(config)

    assert any("above end" in f.message for f in result.errors)


def test_control_plane_address_must_equal_the_gateway(forge_config_module, base_config):
    """The boot server binds to the bridge address; a mismatch means
    nothing answers on the provisioning network."""
    config = copy.deepcopy(base_config)
    config["control_plane"]["address"] = "192.168.250.9"

    result = forge_config_module.validate_semantics(config)

    assert any("must equal provisioning_network.gateway" in f.message for f in result.errors)


# ---------------------------------------------------------------------
# MAC address hygiene
# ---------------------------------------------------------------------


@pytest.mark.parametrize(
    "mac,acceptable,reason",
    [
        ("52:54:00:25:00:21", True, "the QEMU locally-administered unicast prefix"),
        ("02:00:00:00:00:01", True, "locally administered, unicast"),
        ("00:11:22:33:44:55", False, "globally administered: could collide with real hardware"),
        ("53:54:00:25:00:21", False, "multicast bit set: not a valid source address"),
    ],
)
def test_mac_address_must_be_locally_administered_unicast(
    forge_config_module, base_config, mac, acceptable, reason
):
    config = copy.deepcopy(base_config)
    config["hosts"][0]["mac_address"] = mac

    result = forge_config_module.validate_semantics(config)
    rejected = any("locally administered" in f.message for f in result.errors)

    assert rejected is not acceptable, f"{mac}: {reason}"


# ---------------------------------------------------------------------
# Unsupported profiles and invalid resources -- schema level
# ---------------------------------------------------------------------


def test_unsupported_os_profile_is_rejected(forge_config_module, base_config):
    config = copy.deepcopy(base_config)
    config["hosts"][0]["profile"] = "freebsd-server"

    result = forge_config_module.validate_schema(config)

    assert not result.ok
    assert any("profile" in f.path for f in result.errors)


def test_os_family_and_profile_must_agree(forge_config_module, base_config):
    config = copy.deepcopy(base_config)
    config["hosts"][0]["os_family"] = "windows"   # but profile stays ubuntu-server

    result = forge_config_module.validate_schema(config)

    assert not result.ok


@pytest.mark.parametrize(
    "field,value",
    [
        ("vcpu", 0),
        ("vcpu", 999),
        ("memory_mb", 256),
        ("disk_gb", 2),
        ("firmware", "coreboot"),
        ("disk_bus", "ide"),
    ],
)
def test_invalid_resource_values_are_rejected(forge_config_module, base_config, field, value):
    config = copy.deepcopy(base_config)
    config["hosts"][0][field] = value

    result = forge_config_module.validate_schema(config)

    assert not result.ok, f"{field}={value} should have been rejected"


def test_windows_target_below_the_minimum_is_rejected(forge_config_module, base_config):
    config = copy.deepcopy(base_config)
    windows = next(h for h in config["hosts"] if h["os_family"] == "windows")
    windows["memory_mb"] = 1024

    result = forge_config_module.validate_schema(config)

    assert not result.ok


def test_unknown_configuration_key_is_rejected(forge_config_module, base_config):
    """additionalProperties: false catches a typo in a key name, which
    would otherwise be silently ignored."""
    config = copy.deepcopy(base_config)
    config["provisioning_network"]["gatway"] = "192.168.250.1"

    result = forge_config_module.validate_schema(config)

    assert not result.ok
    assert any("Additional properties" in f.message for f in result.errors)


# ---------------------------------------------------------------------
# Media
# ---------------------------------------------------------------------


def test_missing_windows_media_is_a_warning_not_an_error(forge_config_module, base_config):
    """An Ubuntu-only run is a supported outcome, so an absent Windows
    ISO must not stop validation."""
    config = copy.deepcopy(base_config)
    config["media"]["windows"]["iso_path"] = ""

    result = forge_config_module.validate_semantics(config)

    assert result.ok
    assert any("operator-supplied" in f.message for f in result.warnings)


def test_missing_windows_media_is_an_error_under_check_media(forge_config_module, base_config):
    config = copy.deepcopy(base_config)
    config["media"]["windows"]["iso_path"] = ""

    result = forge_config_module.validate_semantics(config, check_media=True)

    assert not result.ok


def test_windows_edition_must_be_selected(forge_config_module, base_config):
    """Index 1 is not a safe assumption, so neither name nor index means
    no selection at all."""
    config = copy.deepcopy(base_config)
    config["media"]["windows"]["image_name"] = ""
    config["media"]["windows"]["image_index"] = 0

    result = forge_config_module.validate_semantics(config)

    assert not result.ok
    assert any("index 1 is not a safe assumption" in f.message for f in result.errors)


def test_nonexistent_media_path_is_caught_under_check_media(forge_config_module, base_config, tmp_path):
    config = copy.deepcopy(base_config)
    config["media"]["ubuntu"]["iso_path"] = str(tmp_path / "absent.iso")
    config["media"]["windows"]["iso_path"] = str(tmp_path / "absent-windows.iso")

    result = forge_config_module.validate_semantics(config, check_media=True)

    assert not result.ok
    assert any("file not found" in f.message for f in result.errors)


# ---------------------------------------------------------------------
# Secret hygiene
# ---------------------------------------------------------------------


def test_plaintext_secret_in_configuration_is_rejected(forge_config_module, base_config):
    config = copy.deepcopy(base_config)
    config["gitops"]["api_token"] = "ghp_realLookingTokenValue1234567890"

    # The schema rejects the unknown key; semantics reject the value.
    semantic = forge_config_module.validate_semantics(config)

    assert not semantic.ok
    assert any("live secret" in f.message for f in semantic.errors)


def test_windows_product_key_must_stay_empty(forge_config_module, base_config):
    config = copy.deepcopy(base_config)
    config["media"]["windows"]["product_key"] = "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"

    result = forge_config_module.validate_schema(config)

    assert not result.ok, "a product key in version control must be rejected"


def test_policy_keys_containing_secret_words_are_not_flagged(forge_config_module, base_config):
    """ssh_password_authentication and destroy_confirmation_token are
    policy, not credentials. Flagging them would train operators to
    ignore the check."""
    result = forge_config_module.validate_semantics(base_config)

    flagged = [f.path for f in result.errors if "live secret" in f.message]
    assert flagged == [], flagged


def test_placeholder_values_are_not_flagged(forge_config_module, base_config):
    config = copy.deepcopy(base_config)
    config["gitops"]["some_token"] = "CHANGEME"

    result = forge_config_module.validate_semantics(config)

    assert not any("live secret" in f.message for f in result.errors)


def test_weak_destroy_confirmation_token_is_rejected(forge_config_module, base_config):
    config = copy.deepcopy(base_config)
    config["safety"]["destroy_confirmation_token"] = "yes"

    result = forge_config_module.validate_semantics(config)

    assert not result.ok


# ---------------------------------------------------------------------
# Loader behaviour
# ---------------------------------------------------------------------


def test_deep_merge_overlays_nested_keys(forge_config_module):
    base = {"a": {"b": 1, "c": 2}, "d": 3}
    overlay = {"a": {"b": 99}}

    merged = forge_config_module.deep_merge(base, overlay)

    assert merged == {"a": {"b": 99, "c": 2}, "d": 3}


def test_deep_merge_replaces_lists_wholesale(forge_config_module):
    """An operator who sets dns_servers means exactly that list, not the
    union with the defaults."""
    base = {"net": {"dns": ["1.1.1.1", "9.9.9.9"]}}
    overlay = {"net": {"dns": ["10.0.0.1"]}}

    merged = forge_config_module.deep_merge(base, overlay)

    assert merged["net"]["dns"] == ["10.0.0.1"]


def test_deep_merge_does_not_mutate_its_inputs(forge_config_module):
    base = {"a": {"b": 1}}
    overlay = {"a": {"b": 2}}

    forge_config_module.deep_merge(base, overlay)

    assert base == {"a": {"b": 1}}


def test_lookup_helpers(forge_config_module, base_config):
    host = forge_config_module.host_by_name(base_config, "poc-ubuntu-01")
    assert host["os_family"] == "linux"

    by_mac = forge_config_module.host_by_mac(base_config, host["mac_address"].upper())
    assert by_mac["name"] == "poc-ubuntu-01"

    with pytest.raises(KeyError):
        forge_config_module.host_by_name(base_config, "no-such-host")


def test_boot_base_url_is_derived_from_the_configuration(forge_config_module, base_config):
    url = forge_config_module.boot_base_url(base_config)
    assert url == f"http://{base_config['control_plane']['address']}:{base_config['control_plane']['boot_http_port']}"
