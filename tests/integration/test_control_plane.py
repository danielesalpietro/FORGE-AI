"""Integration tests against a live control plane.

These need `make deploy-control-plane` to have run. They are skipped
automatically when the endpoints are not answering, so the same suite
runs in CI (where it skips) and on a KVM host (where it does not).

    pytest tests/integration -m integration
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request

import pytest

pytestmark = pytest.mark.integration


# Kept short: on a machine with no control plane every one of these
# would otherwise wait for a full TCP timeout, turning a skipped module
# into a minute of nothing.
HTTP_TIMEOUT = 3


def http_get(url: str, timeout: int = HTTP_TIMEOUT):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:  # noqa: S310
            return response.status, response.read().decode("utf-8", "replace")
    except (urllib.error.URLError, OSError) as exc:
        pytest.skip(f"{url} is not reachable ({exc}); is the control plane running?")


@pytest.fixture(scope="module", autouse=True)
def require_control_plane(boot_url):
    """Probe once, then skip the whole module.

    Without this, every test in the file pays its own connection
    timeout and a skipped module takes a minute.
    """
    try:
        with urllib.request.urlopen(f"{boot_url}/healthz", timeout=HTTP_TIMEOUT):
            return
    except (urllib.error.URLError, OSError) as exc:
        pytest.skip(
            f"no control plane at {boot_url} ({exc}). "
            "Run `make deploy-control-plane` to exercise these tests.",
            allow_module_level=True,
        )


@pytest.fixture(scope="module")
def boot_url(request):
    import sys
    from pathlib import Path

    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "lib"))
    import forge_config

    config = forge_config.load_config()
    return forge_config.boot_base_url(config)


@pytest.fixture(scope="module")
def config():
    import sys
    from pathlib import Path

    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "lib"))
    import forge_config

    return forge_config.load_config()


# ---------------------------------------------------------------------
# Boot artefact server
# ---------------------------------------------------------------------


def test_boot_server_is_healthy(boot_url):
    status, body = http_get(f"{boot_url}/healthz")

    assert status == 200
    assert json.loads(body)["status"] == "ok"


def test_boot_server_serves_the_ipxe_entry_point(boot_url):
    status, body = http_get(f"{boot_url}/boot/boot.ipxe")

    assert status == 200
    assert body.startswith("#!ipxe")
    assert "${mac:hexhyp}" in body


def test_boot_server_refuses_to_list_its_root(boot_url):
    """An autoindex of /srv/http would expose every rendered answer file."""
    try:
        status, body = http_get(f"{boot_url}/windows/")
    except SystemExit:
        return
    assert "Index of" not in body


# ---------------------------------------------------------------------
# Provisioning state service
# ---------------------------------------------------------------------


def test_state_service_is_healthy(boot_url):
    status, body = http_get(f"{boot_url}/api/healthz")
    payload = json.loads(body)

    assert status == 200
    assert payload["component"] == "forge-state"
    assert payload["max_install_attempts"] >= 1


def test_state_service_knows_every_configured_host(boot_url, config):
    _, body = http_get(f"{boot_url}/api/healthz")
    payload = json.loads(body)

    assert payload["known_hosts"] == len(config["hosts"]), (
        "registry.json is out of step with config/poc.yml; re-run make deploy-pxe"
    )


def test_every_host_receives_a_valid_dispatch_script(boot_url, config):
    for host in config["hosts"]:
        mac = host["mac_address"].lower().replace(":", "-")
        status, body = http_get(f"{boot_url}/state/{mac}.ipxe")

        assert status == 200, host["name"]
        assert body.startswith("#!ipxe"), host["name"]


def test_dispatch_responses_are_not_cacheable(boot_url, config):
    """A cached dispatch script would keep serving the installer after a
    host had already installed."""
    mac = config["hosts"][0]["mac_address"].lower().replace(":", "-")
    request = urllib.request.Request(f"{boot_url}/state/{mac}.ipxe")
    try:
        with urllib.request.urlopen(request, timeout=5) as response:  # noqa: S310
            assert "no-store" in response.headers.get("Cache-Control", "")
    except (urllib.error.URLError, OSError) as exc:
        pytest.skip(f"state service unreachable: {exc}")


def test_state_mutation_requires_the_token_when_one_is_configured(boot_url, config):
    _, body = http_get(f"{boot_url}/api/healthz")
    if json.loads(body)["auth"] != "token":
        pytest.skip("the state service is running unauthenticated")

    mac = config["hosts"][0]["mac_address"].lower().replace(":", "-")
    request = urllib.request.Request(
        f"{boot_url}/api/state/{mac}",
        data=json.dumps({"state": "failed"}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with pytest.raises(urllib.error.HTTPError) as caught:
        urllib.request.urlopen(request, timeout=5)  # noqa: S310
    assert caught.value.code == 401


# ---------------------------------------------------------------------
# Seeds and answer files
# ---------------------------------------------------------------------


def test_the_ubuntu_seed_is_served_at_the_exact_url_the_installer_requests(boot_url, config):
    import yaml

    for host in config["hosts"]:
        if host["os_family"] != "linux":
            continue
        status, body = http_get(f"{boot_url}/ubuntu/{host['name']}/user-data")

        assert status == 200
        parsed = yaml.safe_load(body)
        assert parsed["autoinstall"]["identity"]["hostname"] == host["name"]


def test_the_ubuntu_seed_holds_a_hash_not_a_password(boot_url, config):
    import yaml

    for host in config["hosts"]:
        if host["os_family"] != "linux":
            continue
        _, body = http_get(f"{boot_url}/ubuntu/{host['name']}/user-data")
        password = yaml.safe_load(body)["autoinstall"]["identity"]["password"]
        assert password.startswith("$"), "a cleartext password is being served over HTTP"
