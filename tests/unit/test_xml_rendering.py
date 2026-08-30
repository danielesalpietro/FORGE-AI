"""XML artefacts must parse and carry the elements Windows requires.

Windows Setup ignores a malformed Autounattend.xml *silently* and falls
back to an interactive installation. On a headless VM that presents as
a hang, hours after the mistake was made. Parsing it here costs
milliseconds.
"""

from __future__ import annotations

import sys
from pathlib import Path
from xml.etree import ElementTree

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "fixtures"))
import render_context  # noqa: E402

UNATTEND_NAMESPACE = "urn:schemas-microsoft-com:unattend"
NS = {"u": UNATTEND_NAMESPACE}


@pytest.fixture()
def windows_host(base_config):
    hosts = [h for h in base_config["hosts"] if h["os_family"] == "windows"]
    if not hosts:
        pytest.skip("no Windows host in the configuration")
    return hosts[0]


@pytest.fixture()
def unattend_xml(jinja_env, base_config, windows_host):
    context = render_context.build_context(base_config, host=windows_host)
    return jinja_env.get_template("windows/Autounattend.xml.j2").render(**context)


@pytest.fixture()
def unattend_tree(unattend_xml):
    return ElementTree.fromstring(unattend_xml)


# ---------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------


def test_autounattend_is_well_formed_xml(unattend_xml):
    ElementTree.fromstring(unattend_xml)


def test_autounattend_uses_the_expected_namespace(unattend_tree):
    assert unattend_tree.tag == f"{{{UNATTEND_NAMESPACE}}}unattend"


@pytest.mark.parametrize(
    "pass_name,consequence_if_missing",
    [
        ("windowsPE", "Setup asks for the disk layout and the edition interactively"),
        ("specialize", "no computer name, and SetupComplete.cmd is never staged"),
        ("oobeSystem", "Setup stops at the region and keyboard screen forever"),
    ],
)
def test_autounattend_carries_every_required_pass(unattend_tree, pass_name, consequence_if_missing):
    settings = unattend_tree.findall(f"u:settings[@pass='{pass_name}']", NS)
    assert settings, f"missing pass '{pass_name}': {consequence_if_missing}"


def test_disk_configuration_is_uefi_gpt(unattend_tree):
    """Three partitions: EFI, MSR, Windows. Anything else and the
    firmware has nothing to boot."""
    partitions = unattend_tree.findall(
        ".//u:DiskConfiguration/u:Disk/u:CreatePartitions/u:CreatePartition", NS
    )
    types = [p.find("u:Type", NS).text for p in partitions]

    assert types == ["EFI", "MSR", "Primary"], types
    extend = partitions[2].find("u:Extend", NS)
    assert extend is not None and extend.text == "true", "the Windows partition must fill the disk"


def test_disk_is_wiped_so_a_retry_is_deterministic(unattend_tree):
    wipe = unattend_tree.find(".//u:DiskConfiguration/u:Disk/u:WillWipeDisk", NS)
    assert wipe is not None and wipe.text == "true", (
        "a leftover ESP from a previous attempt is the most common cause of a "
        "silent 'Windows cannot be installed to this disk'"
    )


def test_edition_is_selected_explicitly(unattend_tree, base_config):
    """Index 1 on a Server ISO is usually Standard Core, not what an
    operator expects. The answer file must say which edition it means."""
    metadata = unattend_tree.find(".//u:ImageInstall/u:OSImage/u:InstallFrom/u:MetaData", NS)
    assert metadata is not None, "no edition selection at all"

    key = metadata.find("u:Key", NS).text
    value = metadata.find("u:Value", NS).text

    assert key in ("/IMAGE/NAME", "/IMAGE/INDEX")
    if key == "/IMAGE/NAME":
        assert value == base_config["media"]["windows"]["image_name"]
    else:
        assert int(value) > 0, "index 0 is not a valid selection"


def test_installs_to_the_windows_partition(unattend_tree):
    install_to = unattend_tree.find(".//u:ImageInstall/u:OSImage/u:InstallTo", NS)
    assert install_to.find("u:DiskID", NS).text == "0"
    assert install_to.find("u:PartitionID", NS).text == "3", (
        "partition 3 is the Windows partition; 1 is the ESP and 2 is the MSR"
    )


def test_no_driver_paths_block_survives(unattend_tree):
    """The Server 2025 setup engine rejects PathAndCredentials outright
    at parse time (bug 32, CSI E_INVALIDARG "name in handler = 0") and
    aborts the whole windowsPE pass. Drivers travel via setup.exe
    /InstallDrivers instead -- covered by the startnet.cmd test below.
    Reintroducing DriverPaths would silently kill unattended installs."""
    assert unattend_tree.findall(".//u:DriverPaths", NS) == [], (
        "DriverPaths must NOT be in the answer file: this setup engine "
        "rejects it and the whole windowsPE pass fails (bug 32)"
    )


def test_startnet_passes_installdrivers(jinja_env, base_config, windows_host):
    """The /InstallDrivers flag is what carries the VirtIO drivers into
    the installed OS now that DriverPaths is gone. Without it the OS
    installs, boots, and then has no network -- the specialize-phase
    downloads fail and the pipeline stalls late and confusingly."""
    script = jinja_env.get_template("windows/startnet.cmd.j2").render(
        **render_context.build_context(base_config, host=windows_host)
    )
    assert "/InstallDrivers" in script
    assert "forge-install-drivers" in script


def test_computer_name_is_set_and_within_the_netbios_limit(unattend_tree, windows_host):
    computer_name = unattend_tree.find(".//u:settings[@pass='specialize']//u:ComputerName", NS)
    assert computer_name is not None
    assert len(computer_name.text) <= 15, "Windows truncates NetBIOS names at 15 characters"
    assert computer_name.text == windows_host["name"].upper()[:15]


def test_setupcomplete_is_staged_during_specialize(unattend_tree):
    """Without this the host installs but never gets a WinRM listener."""
    commands = [
        c.find("u:Path", NS).text
        for c in unattend_tree.findall(".//u:RunSynchronous/u:RunSynchronousCommand", NS)
    ]
    joined = " ".join(commands)

    assert "SetupComplete.cmd" in joined
    assert "Configure-WinRM.ps1" in joined
    assert "/api/state/" in joined, "the specialize pass must report state=installed"


def test_specialize_commands_are_ordered(unattend_tree):
    orders = [
        int(c.find("u:Order", NS).text)
        for c in unattend_tree.findall(".//u:RunSynchronous/u:RunSynchronousCommand", NS)
    ]
    assert orders == sorted(orders), "RunSynchronousCommand Order values must ascend"
    assert len(orders) == len(set(orders)), "duplicate Order values are ambiguous"


def test_oobe_is_fully_suppressed(unattend_tree):
    """Any un-suppressed OOBE screen stops an unattended install dead."""
    oobe = unattend_tree.find(".//u:settings[@pass='oobeSystem']//u:OOBE", NS)
    assert oobe is not None

    for element in ("HideEULAPage", "HideLocalAccountScreen", "HideOEMRegistrationScreen",
                    "HideOnlineAccountScreens", "HideWirelessSetupInOOBE"):
        node = oobe.find(f"u:{element}", NS)
        assert node is not None and node.text == "true", f"{element} is not suppressed"


def test_eula_is_accepted(unattend_tree):
    eula = unattend_tree.find(".//u:UserData/u:AcceptEula", NS)
    assert eula is not None and eula.text == "true"


# ---------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------


def test_administrator_password_is_not_plaintext(unattend_tree):
    password = unattend_tree.find(".//u:UserAccounts/u:AdministratorPassword", NS)
    assert password is not None

    plaintext = password.find("u:PlainText", NS)
    assert plaintext is not None and plaintext.text == "false", (
        "PlainText=true would put the real password in a file served over HTTP"
    )


def test_cleartext_password_never_appears_in_the_answer_file(unattend_xml):
    cleartext = render_context.FIXTURE_VAULT["vault_windows_admin_password"]
    assert cleartext not in unattend_xml


def test_encoded_password_round_trips(unattend_tree):
    """Windows expects Base64(UTF-16LE(password + field-name)). Getting
    this wrong leaves the Administrator account with no password, and
    the host installs perfectly but rejects every login."""
    import base64

    value = unattend_tree.find(".//u:UserAccounts/u:AdministratorPassword/u:Value", NS).text
    decoded = base64.b64decode(value).decode("utf-16-le")

    expected = render_context.FIXTURE_VAULT["vault_windows_admin_password"]
    assert decoded == f"{expected}AdministratorPassword"


def test_no_product_key_is_emitted_for_evaluation_media(unattend_tree):
    """Activation is out of scope; Evaluation media installs unkeyed."""
    assert unattend_tree.find(".//u:UserData/u:ProductKey", NS) is None


def test_rdp_follows_the_configuration(jinja_env, base_config, windows_host):
    for enabled in (True, False):
        config = {**base_config, "security": {**base_config["security"], "windows_rdp_enabled": enabled}}
        context = render_context.build_context(config, host=windows_host)
        tree = ElementTree.fromstring(
            jinja_env.get_template("windows/Autounattend.xml.j2").render(**context)
        )
        deny = tree.find(".//u:fDenyTSConnections", NS)
        assert deny.text == ("false" if enabled else "true")


# ---------------------------------------------------------------------
# libvirt XML
# ---------------------------------------------------------------------


def test_network_xml_is_well_formed(jinja_env, base_config):
    xml = jinja_env.get_template("libvirt/network.xml.j2").render(
        **render_context.build_context(base_config)
    )
    ElementTree.fromstring(xml)


def test_network_xml_has_no_dhcp_or_dns(jinja_env, base_config):
    """libvirt only spawns its own dnsmasq when a network needs DHCP or
    DNS. Two DHCP servers on one bridge is the classic cause of
    intermittent PXE failure."""
    xml = jinja_env.get_template("libvirt/network.xml.j2").render(
        **render_context.build_context(base_config)
    )
    tree = ElementTree.fromstring(xml)

    assert tree.find(".//dhcp") is None, "a <dhcp> element would start libvirt's own dnsmasq"
    dns = tree.find("dns")
    assert dns is not None and dns.get("enable") == "no"


def test_domain_xml_is_well_formed_for_every_host(jinja_env, base_config):
    for host in base_config["hosts"]:
        xml = jinja_env.get_template("libvirt/domain.xml.j2").render(
            **render_context.build_context(base_config, host=host)
        )
        ElementTree.fromstring(xml)


def test_domain_boot_order_follows_forge_boot_target(jinja_env, base_config):
    """This is half the reinstall-loop guard: an installed VM must
    prefer its own disk even if the state service were lost."""
    host = base_config["hosts"][0]

    for target, expected_first in (("network", "network"), ("hd", "hd")):
        xml = jinja_env.get_template("libvirt/domain.xml.j2").render(
            **render_context.build_context(base_config, host=host, forge_boot_target=target)
        )
        tree = ElementTree.fromstring(xml)
        boot_devices = [b.get("dev") for b in tree.findall("os/boot")]
        assert boot_devices[0] == expected_first, f"{target}: {boot_devices}"
        assert set(boot_devices) == {"network", "hd"}


def test_domain_resources_match_the_configuration(jinja_env, base_config):
    for host in base_config["hosts"]:
        tree = ElementTree.fromstring(
            jinja_env.get_template("libvirt/domain.xml.j2").render(
                **render_context.build_context(base_config, host=host)
            )
        )
        assert tree.findtext("name") == host["name"]
        assert int(tree.findtext("memory")) == host["memory_mb"]
        assert int(tree.findtext("vcpu")) == host["vcpu"]
        assert tree.find("devices/interface/mac").get("address") == host["mac_address"]


def test_windows_domain_gets_hyperv_enlightenments(jinja_env, base_config):
    """A measurable performance difference for Windows guests on KVM."""
    for host in base_config["hosts"]:
        tree = ElementTree.fromstring(
            jinja_env.get_template("libvirt/domain.xml.j2").render(
                **render_context.build_context(base_config, host=host)
            )
        )
        hyperv = tree.find("features/hyperv")
        if host["os_family"] == "windows":
            assert hyperv is not None, "Windows guests should get Hyper-V enlightenments"
        else:
            assert hyperv is None, "Linux guests do not need them"


def test_every_domain_has_a_serial_console_and_guest_agent(jinja_env, base_config):
    """virsh console is the only way to watch a headless install, and the
    guest agent is how the smoke test reads the real IP."""
    for host in base_config["hosts"]:
        tree = ElementTree.fromstring(
            jinja_env.get_template("libvirt/domain.xml.j2").render(
                **render_context.build_context(base_config, host=host)
            )
        )
        assert tree.find("devices/serial") is not None
        channels = [c.find("target").get("name") for c in tree.findall("devices/channel")]
        assert "org.qemu.guest_agent.0" in channels


def test_vnc_listens_only_on_loopback(jinja_env, base_config):
    """A VNC console bound to 0.0.0.0 is unauthenticated console access
    to a machine from anywhere that can route to the host."""
    for host in base_config["hosts"]:
        tree = ElementTree.fromstring(
            jinja_env.get_template("libvirt/domain.xml.j2").render(
                **render_context.build_context(base_config, host=host)
            )
        )
        graphics = tree.find("devices/graphics")
        assert graphics.get("listen") == "127.0.0.1"
