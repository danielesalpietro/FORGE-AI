"""iPXE host selection and the reinstall-loop guard.

The dispatch decision -- what a given MAC receives on its next network
boot -- is the single most consequential piece of logic in the project.
Get it wrong in one direction and a machine never installs; get it wrong
in the other and it reinstalls forever, which looks like "busy" rather
than "broken".

These tests exercise the real state service from
``compose/state-service/app.py``, not a reimplementation.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "fixtures"))
import render_context  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
STATE_SERVICE = REPO_ROOT / "compose" / "state-service" / "app.py"


@pytest.fixture()
def state_service(tmp_path, monkeypatch, base_config):
    """Import the real state service with its storage pointed at tmp."""
    state_dir = tmp_path / "state"
    log_dir = tmp_path / "logs"
    state_dir.mkdir()
    log_dir.mkdir()

    registry = {
        "hosts": {
            host["mac_address"].lower().replace(":", "-"): {
                "name": host["name"],
                "profile": host["profile"],
                "ip_address": host["ip_address"],
            }
            for host in base_config["hosts"]
        }
    }
    (state_dir / "registry.json").write_text(json.dumps(registry))

    monkeypatch.setenv("FORGE_STATE_DIR", str(state_dir))
    monkeypatch.setenv("FORGE_LOG_DIR", str(log_dir))
    monkeypatch.setenv("FORGE_REGISTRY", str(state_dir / "registry.json"))
    monkeypatch.setenv("FORGE_MAX_INSTALL_ATTEMPTS", "3")
    monkeypatch.setenv("FORGE_BOOT_BASE_URL", "http://192.168.250.1:8080")

    # Fresh import each time so the module-level configuration is re-read.
    sys.modules.pop("forge_state_app", None)
    spec = importlib.util.spec_from_file_location("forge_state_app", STATE_SERVICE)
    module = importlib.util.module_from_spec(spec)
    sys.modules["forge_state_app"] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def ubuntu_mac(base_config):
    host = next(h for h in base_config["hosts"] if h["os_family"] == "linux")
    return host["mac_address"].lower().replace(":", "-")


@pytest.fixture()
def windows_mac(base_config):
    host = next(h for h in base_config["hosts"] if h["os_family"] == "windows")
    return host["mac_address"].lower().replace(":", "-")


# ---------------------------------------------------------------------
# Host selection by MAC
# ---------------------------------------------------------------------


def test_a_new_host_is_offered_its_installer(state_service, ubuntu_mac):
    status, script = state_service.dispatch(ubuntu_mac)

    assert status == 200
    assert script.startswith("#!ipxe")
    assert f"host-{ubuntu_mac}-install.ipxe" in script


def test_each_mac_gets_its_own_installer(state_service, ubuntu_mac, windows_mac):
    _, ubuntu_script = state_service.dispatch(ubuntu_mac)
    _, windows_script = state_service.dispatch(windows_mac)

    assert ubuntu_mac in ubuntu_script and windows_mac not in ubuntu_script
    assert windows_mac in windows_script and ubuntu_mac not in windows_script
    assert "ubuntu-server" in ubuntu_script
    assert "windows-server" in windows_script


def test_an_unknown_mac_falls_through_to_the_menu(state_service):
    status, script = state_service.dispatch("aa-bb-cc-dd-ee-ff")

    assert status == 200
    assert "menu.ipxe" in script
    assert "not defined in config/poc.yml" in script


def test_dispatch_moves_a_new_host_to_installing(state_service, ubuntu_mac):
    state_service.dispatch(ubuntu_mac)

    record = state_service.read_state(ubuntu_mac)
    assert record["state"] == "installing"
    assert record["attempts"] == 1


# ---------------------------------------------------------------------
# The reinstall-loop guard
# ---------------------------------------------------------------------


def test_attempts_increment_on_every_dispatch(state_service, ubuntu_mac):
    for expected in (1, 2, 3):
        state_service.dispatch(ubuntu_mac)
        assert state_service.read_state(ubuntu_mac)["attempts"] == expected


def test_the_installer_stops_being_offered_at_the_limit(state_service, ubuntu_mac):
    """Three attempts are allowed; the fourth boot must not reinstall."""
    for _ in range(3):
        status, script = state_service.dispatch(ubuntu_mac)
        assert "install.ipxe" in script

    status, script = state_service.dispatch(ubuntu_mac)

    assert status == 200
    assert "install.ipxe" not in script
    # bug 22 (docs/logbook/05-fase6-provisioning-target-vm.md): sanboot
    # is a BIOS/legacy trick that fails on UEFI guests; local boot falls
    # through to firmware via a plain `exit` instead.
    assert "exit" in script
    assert "refusing to reinstall" in script


def test_a_host_at_the_limit_is_parked_as_failed(state_service, ubuntu_mac):
    for _ in range(4):
        state_service.dispatch(ubuntu_mac)

    record = state_service.read_state(ubuntu_mac)
    assert record["state"] == "failed"
    assert any("attempt limit" in entry.get("detail", "") for entry in record["history"])


def test_the_guard_stays_engaged_on_further_boots(state_service, ubuntu_mac):
    """A parked host must not start reinstalling again by itself."""
    for _ in range(8):
        _, script = state_service.dispatch(ubuntu_mac)

    assert "install.ipxe" not in script
    assert state_service.read_state(ubuntu_mac)["state"] == "failed"


def test_resetting_to_new_clears_the_attempt_counter(state_service, ubuntu_mac):
    """This is how an operator deliberately requests a rebuild."""
    for _ in range(4):
        state_service.dispatch(ubuntu_mac)
    assert state_service.read_state(ubuntu_mac)["state"] == "failed"

    record = state_service.read_state(ubuntu_mac)
    ok, _ = state_service.transition(record, "new", source="test")
    state_service.write_state(record)

    assert ok
    assert record["attempts"] == 0

    _, script = state_service.dispatch(ubuntu_mac)
    assert "install.ipxe" in script


# ---------------------------------------------------------------------
# Local boot for an installed host
# ---------------------------------------------------------------------


@pytest.mark.parametrize("state", ["installed", "configuring", "ready"])
def test_an_installed_host_boots_locally(state_service, ubuntu_mac, state):
    record = state_service.read_state(ubuntu_mac)
    for step in {"installed": ["installed"],
                 "configuring": ["installed", "configuring"],
                 "ready": ["installed", "configuring", "ready"]}[state]:
        assert state_service.transition(record, step, source="test")[0]
    state_service.write_state(record)

    _, script = state_service.dispatch(ubuntu_mac)

    # bug 22: sanboot fails on UEFI guests, local boot uses a plain exit.
    assert "exit" in script
    assert "install.ipxe" not in script
    assert f"state={state}" in script


def test_dispatching_an_installed_host_does_not_burn_an_attempt(state_service, ubuntu_mac):
    record = state_service.read_state(ubuntu_mac)
    state_service.transition(record, "installed", source="test")
    state_service.write_state(record)

    state_service.dispatch(ubuntu_mac)
    state_service.dispatch(ubuntu_mac)

    assert state_service.read_state(ubuntu_mac)["attempts"] == 0


# ---------------------------------------------------------------------
# State machine integrity
# ---------------------------------------------------------------------


@pytest.mark.parametrize(
    "from_state,to_state,allowed",
    [
        ("new", "installing", True),
        ("installing", "installed", True),
        ("installed", "configuring", True),
        ("configuring", "ready", True),
        ("ready", "configuring", True),      # reconciliation
        ("installing", "failed", True),
        ("failed", "new", True),             # a deliberate rebuild
        ("ready", "installing", False),      # would mean a silent reinstall
        ("ready", "installed", False),
        ("configuring", "installing", False),
        ("installed", "installing", False),
    ],
)
def test_transition_rules(state_service, from_state, to_state, allowed):
    record = {"mac": "52-54-00-25-00-21", "state": from_state, "attempts": 0, "history": []}

    ok, message = state_service.transition(record, to_state, source="test")

    assert ok is allowed, f"{from_state} -> {to_state}: {message}"


def test_an_unknown_state_is_rejected(state_service):
    record = {"mac": "52-54-00-25-00-21", "state": "new", "attempts": 0, "history": []}

    ok, message = state_service.transition(record, "provisioning", source="test")

    assert not ok
    assert "unknown state" in message


def test_history_is_bounded(state_service, ubuntu_mac):
    """A host stuck in a loop must not fill the disk with history."""
    record = state_service.read_state(ubuntu_mac)
    for index in range(200):
        record["state"] = "new"
        state_service.transition(record, "installing", source=f"test-{index}")

    assert len(record["history"]) <= 50


def test_a_corrupt_state_file_is_treated_as_new(state_service, ubuntu_mac, tmp_path):
    """A truncated write must not wedge a host permanently."""
    state_service.state_path(ubuntu_mac).write_text("{not json")

    record = state_service.read_state(ubuntu_mac)

    assert record["state"] == "new"
    assert any(entry.get("event") == "state-file-corrupt" for entry in record["history"])


def test_state_writes_are_atomic(state_service, ubuntu_mac):
    """os.replace, so a concurrent reader never sees a half-written file."""
    record = state_service.read_state(ubuntu_mac)
    state_service.write_state(record)

    path = state_service.state_path(ubuntu_mac)
    assert path.is_file()
    assert not path.with_suffix(".json.tmp").exists()
    json.loads(path.read_text())


# ---------------------------------------------------------------------
# The iPXE scripts the dispatcher points at
# ---------------------------------------------------------------------


def test_boot_script_dispatches_by_mac(jinja_env, base_config):
    script = jinja_env.get_template("ipxe/boot.ipxe.j2").render(
        **render_context.build_context(base_config)
    )

    assert script.startswith("#!ipxe")
    assert "${mac:hexhyp}" in script, "per-host dispatch keys on the MAC in hyphen form"
    assert "/state/" in script
    assert "goto unknown_host" in script or "|| goto" in script


def test_boot_script_has_a_local_disk_fallback(jinja_env, base_config):
    script = jinja_env.get_template("ipxe/boot.ipxe.j2").render(
        **render_context.build_context(base_config)
    )
    # bug 22: sanboot fails on UEFI guests, local boot uses a plain exit.
    assert "exit" in script
    assert ":localboot" in script


def test_menu_offers_every_configured_host(jinja_env, base_config):
    script = jinja_env.get_template("ipxe/menu.ipxe.j2").render(
        **render_context.build_context(base_config)
    )

    for host in base_config["hosts"]:
        assert host["name"] in script
        assert host["mac_address"].replace(":", "-") in script


def test_menu_defaults_to_local_boot(jinja_env, base_config):
    """If nobody is watching, the safe default is to boot what is already
    installed -- not to start an installation."""
    script = jinja_env.get_template("ipxe/menu.ipxe.j2").render(
        **render_context.build_context(base_config)
    )
    assert "--default local" in script
    assert "--timeout ${timeout}" in script


def test_ubuntu_install_script_seeds_with_a_trailing_slash(jinja_env, base_config):
    """cloud-init appends filenames to s= verbatim. Without the trailing
    slash the installer requests '...poc-ubuntu-01user-data', gets a 404,
    and waits at an interactive prompt forever."""
    host = next(h for h in base_config["hosts"] if h["os_family"] == "linux")
    script = jinja_env.get_template("ipxe/host-ubuntu-install.ipxe.j2").render(
        **render_context.build_context(base_config, host=host)
    )

    assert f"/ubuntu/{host['name']}/" in script
    assert "ds=nocloud;s=${seed}" in script
    assert "autoinstall" in script


def test_windows_install_script_fetches_the_wimboot_file_set(jinja_env, base_config):
    """wimboot needs all four, plus the per-host startnet.cmd it injects
    into \\Windows\\System32. Autounattend.xml deliberately does NOT
    travel this way (bug 28/30, docs/logbook/06-fase6-provisioning-windows.md):
    it arrives on a separate CD-ROM instead, see domain.xml.j2."""
    host = next(h for h in base_config["hosts"] if h["os_family"] == "windows")
    script = jinja_env.get_template("ipxe/host-windows-install.ipxe.j2").render(
        **render_context.build_context(base_config, host=host)
    )

    for required in ("wimboot", "bootmgr.exe", "BCD", "boot.sdi", "boot.wim"):
        assert required in script, f"{required} missing from the wimboot file set"

    assert "startnet.cmd" in script

    fetch_lines = [line for line in script.splitlines() if line.strip().startswith("imgfetch")]
    assert any("winpeshl.ini" in line for line in fetch_lines), (
        "without an injected winpeshl.ini the Setup image launches "
        "X:\\sources\\setup.exe directly and startnet.cmd never runs (bug 28/32)"
    )
    assert not any("Autounattend.xml" in line for line in fetch_lines), (
        "the answer file travels on a separate CD-ROM, not through wimboot injection"
    )
