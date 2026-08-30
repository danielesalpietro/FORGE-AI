#!/usr/bin/env python3
"""FORGE-AI provisioning state service.

A deliberately small HTTP service -- Python standard library only, no
framework, no database -- that owns three jobs the rest of the platform
cannot do on its own:

1. **iPXE dispatch.** ``GET /state/<mac>.ipxe`` returns an iPXE script
   chosen by the host's position in its lifecycle. This is what stops a
   freshly installed machine from booting straight back into the
   installer.

2. **Reinstall-loop guard.** Every dispatch that hands out an installer
   increments an attempt counter. Past ``max_install_attempts`` the
   service refuses to offer the installer again and parks the host in
   ``failed``. Without this, a host that fails halfway through
   installation reinstalls forever and looks "busy" rather than broken.

3. **Callbacks and logs.** ``POST /api/state/<mac>`` is what the Ubuntu
   late-commands and the Windows SetupComplete.cmd call to announce
   ``installed`` / ``failed``. ``POST /api/log/<host>/<name>`` accepts
   installer logs so a failed run is diagnosable without console access.

State machine
-------------

    new -> installing -> installed -> configuring -> ready
             |                                        ^
             +--> failed <----------------------------+

Transitions are validated: an out-of-order report is rejected with 409
rather than silently corrupting the lifecycle.

Security posture
----------------

This service listens **only** on the isolated provisioning network. It
performs no authentication on GET (an iPXE ROM cannot present a
credential) and optional shared-token authentication on the mutating
endpoints, enabled by setting ``FORGE_STATE_TOKEN``. Anyone who can put
a frame on the provisioning bridge can therefore read boot scripts.
That trade-off, and the production alternative, are documented in
docs/SECURITY.md ("malicious PXE server").
"""

from __future__ import annotations

import hmac
import json
import logging
import os
import re
import signal
import sys
import threading
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

LOG = logging.getLogger("forge-state")

# --------------------------------------------------------------------
# Configuration (environment driven -- see compose/docker-compose.yml)
# --------------------------------------------------------------------
STATE_DIR = Path(os.environ.get("FORGE_STATE_DIR", "/srv/state"))
LOG_DIR = Path(os.environ.get("FORGE_LOG_DIR", "/srv/logs"))
REGISTRY_PATH = Path(os.environ.get("FORGE_REGISTRY", "/srv/state/registry.json"))
LISTEN_HOST = os.environ.get("FORGE_LISTEN_HOST", "0.0.0.0")  # noqa: S104 - container-internal
LISTEN_PORT = int(os.environ.get("FORGE_LISTEN_PORT", "8090"))
BOOT_BASE_URL = os.environ.get("FORGE_BOOT_BASE_URL", "http://192.168.250.1:8080")
MAX_ATTEMPTS = int(os.environ.get("FORGE_MAX_INSTALL_ATTEMPTS", "3"))
SHARED_TOKEN = os.environ.get("FORGE_STATE_TOKEN", "").strip()
MAX_BODY_BYTES = int(os.environ.get("FORGE_MAX_BODY_BYTES", str(32 * 1024 * 1024)))

MAC_HYPHEN_RE = re.compile(r"^[0-9a-f]{2}(-[0-9a-f]{2}){5}$")
SAFE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")

STATES = ("new", "installing", "installed", "configuring", "ready", "failed")

# Which transitions are legal. "failed" is reachable from anywhere;
# "new" is reachable from anywhere too, because that is what a rebuild
# is. Everything else must move forward.
ALLOWED_TRANSITIONS: dict[str, set[str]] = {
    "new": {"installing", "installed", "failed", "new"},
    "installing": {"installed", "failed", "installing", "new"},
    "installed": {"configuring", "ready", "failed", "installed", "new"},
    "configuring": {"ready", "failed", "configuring", "new"},
    "ready": {"configuring", "failed", "ready", "new"},
    "failed": {"new", "installing", "failed"},
}

# States in which a network boot must still hand out an installer.
INSTALLING_STATES = {"new", "installing"}

_LOCK = threading.Lock()


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# --------------------------------------------------------------------
# Host registry (written by ansible/roles/ipxe_menu)
# --------------------------------------------------------------------


def load_registry() -> dict:
    """MAC -> host metadata, produced from config/poc.yml by Ansible."""
    try:
        with REGISTRY_PATH.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        LOG.warning("registry %s not found; no host is known yet", REGISTRY_PATH)
        return {}
    except (OSError, json.JSONDecodeError) as exc:
        LOG.error("registry %s is unreadable: %s", REGISTRY_PATH, exc)
        return {}
    return {k.lower(): v for k, v in data.get("hosts", {}).items()}


# --------------------------------------------------------------------
# State persistence
# --------------------------------------------------------------------


def state_path(mac: str) -> Path:
    return STATE_DIR / f"{mac}.json"


def read_state(mac: str) -> dict:
    path = state_path(mac)
    if not path.is_file():
        return {
            "mac": mac,
            "state": "new",
            "attempts": 0,
            "created_at": now_iso(),
            "updated_at": now_iso(),
            "history": [],
        }
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        LOG.error("state file %s is corrupt (%s); treating the host as new", path, exc)
        return {
            "mac": mac,
            "state": "new",
            "attempts": 0,
            "created_at": now_iso(),
            "updated_at": now_iso(),
            "history": [{"at": now_iso(), "event": "state-file-corrupt", "detail": str(exc)}],
        }


def write_state(record: dict) -> None:
    """Atomic replace so a concurrent reader never sees a half file."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    path = state_path(record["mac"])
    tmp = path.with_suffix(".json.tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(record, handle, indent=2, sort_keys=False)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)


def transition(record: dict, new_state: str, *, source: str, detail: str = "") -> tuple[bool, str]:
    current = record.get("state", "new")
    if new_state not in STATES:
        return False, f"unknown state {new_state!r}"
    if new_state not in ALLOWED_TRANSITIONS.get(current, set()):
        return False, f"illegal transition {current} -> {new_state}"
    record["state"] = new_state
    record["updated_at"] = now_iso()
    record.setdefault("history", []).append(
        {"at": now_iso(), "from": current, "to": new_state, "source": source, "detail": detail}
    )
    # Keep the history bounded: a stuck host must not fill the disk.
    record["history"] = record["history"][-50:]
    if new_state == "new":
        record["attempts"] = 0
    return True, "ok"


# --------------------------------------------------------------------
# iPXE script generation
# --------------------------------------------------------------------


def script_install(host: dict, record: dict) -> str:
    mac = record["mac"]
    return f"""#!ipxe
# FORGE-AI state service: {host['name']} is {record['state']}
# attempt {record['attempts']} of {MAX_ATTEMPTS}
echo
echo [state] {host['name']}: state={record['state']} attempt={record['attempts']}/{MAX_ATTEMPTS}
echo [state] chaining the {host['profile']} installer
echo
chain --autofree {BOOT_BASE_URL}/boot/host-{mac}-install.ipxe || goto state_failed

:state_failed
echo [error] installer script for {host['name']} could not be loaded
echo         expected {BOOT_BASE_URL}/boot/host-{mac}-install.ipxe
sleep 10
exit 1
"""


def script_local(host: dict | None, record: dict, reason: str) -> str:
    name = host["name"] if host else record["mac"]
    # `sanboot --drive 0x80` is a BIOS/legacy INT13 trick; these guests are
    # UEFI, and iPXE reports "No such device" for it there ("Boot from SAN
    # device 0x80 failed: No such device", confirmed on real hardware via
    # `virsh screenshot`). Plain `exit` returns control to firmware, which
    # then proceeds to the domain's own next boot option (hd) -- the
    # standard iPXE technique for UEFI local-disk fallback.
    return f"""#!ipxe
# FORGE-AI state service: local boot
echo
echo [state] {name}: {reason}
echo [state] booting from local disk
echo
exit
"""


def script_unknown(mac: str) -> str:
    return f"""#!ipxe
# FORGE-AI state service: unknown MAC
echo
echo [state] {mac} is not defined in config/poc.yml
echo [state] falling through to the interactive menu
echo
chain --autofree {BOOT_BASE_URL}/boot/menu.ipxe || exit 1
"""


def dispatch(mac: str) -> tuple[int, str]:
    """Decide what this MAC should boot, and record the decision."""
    registry = load_registry()
    host = registry.get(mac)

    with _LOCK:
        record = read_state(mac)
        record["mac"] = mac
        if host:
            record["host"] = host.get("name")
            record["profile"] = host.get("profile")

        if not host:
            LOG.warning("dispatch for unknown MAC %s", mac)
            record.setdefault("history", []).append(
                {"at": now_iso(), "event": "dispatch-unknown-mac", "source": "ipxe"}
            )
            write_state(record)
            return HTTPStatus.OK, script_unknown(mac)

        state = record.get("state", "new")

        if state not in INSTALLING_STATES:
            record.setdefault("history", []).append(
                {"at": now_iso(), "event": "dispatch-local", "source": "ipxe", "detail": state}
            )
            write_state(record)
            return HTTPStatus.OK, script_local(host, record, f"state={state}, no installation required")

        if record.get("attempts", 0) >= MAX_ATTEMPTS:
            # Loop guard. Park the host instead of reinstalling forever.
            transition(record, "failed", source="state-service",
                       detail=f"install attempt limit ({MAX_ATTEMPTS}) exhausted")
            write_state(record)
            LOG.error("%s exhausted %d install attempts; parking as failed", host["name"], MAX_ATTEMPTS)
            return HTTPStatus.OK, script_local(
                host, record,
                f"install attempt limit ({MAX_ATTEMPTS}) reached - refusing to reinstall",
            )

        record["attempts"] = record.get("attempts", 0) + 1
        if state == "new":
            transition(record, "installing", source="state-service", detail="first dispatch")
        else:
            record.setdefault("history", []).append(
                {"at": now_iso(), "event": "dispatch-install", "source": "ipxe",
                 "detail": f"attempt {record['attempts']}"}
            )
            record["updated_at"] = now_iso()
        write_state(record)
        return HTTPStatus.OK, script_install(host, record)


# --------------------------------------------------------------------
# HTTP layer
# --------------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    server_version = "forge-state/1.0"
    protocol_version = "HTTP/1.1"

    # -- helpers ------------------------------------------------------

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        LOG.info("%s - %s", self.client_address[0], fmt % args)

    def _send(self, status: int, body: bytes, content_type: str = "text/plain; charset=utf-8") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status: int, payload: dict) -> None:
        self._send(status, (json.dumps(payload, indent=2) + "\n").encode("utf-8"), "application/json")

    def _authorised(self) -> bool:
        if not SHARED_TOKEN:
            return True
        presented = self.headers.get("X-Forge-Token", "")
        return hmac.compare_digest(presented, SHARED_TOKEN)

    def _read_body(self) -> bytes:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return b""
        if length > MAX_BODY_BYTES:
            raise ValueError(f"body of {length} bytes exceeds the {MAX_BODY_BYTES} byte limit")
        return self.rfile.read(length) if length > 0 else b""

    # -- routes -------------------------------------------------------

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        path = urlparse(self.path).path

        if path in ("/healthz", "/api/healthz"):
            registry = load_registry()
            self._json(HTTPStatus.OK, {
                "status": "ok",
                "component": "forge-state",
                "known_hosts": len(registry),
                "max_install_attempts": MAX_ATTEMPTS,
                "auth": "token" if SHARED_TOKEN else "none",
            })
            return

        if path == "/api/state":
            with _LOCK:
                records = []
                if STATE_DIR.is_dir():
                    for item in sorted(STATE_DIR.glob("*.json")):
                        if item.name == REGISTRY_PATH.name:
                            continue
                        try:
                            records.append(json.loads(item.read_text(encoding="utf-8")))
                        except (OSError, json.JSONDecodeError):
                            continue
            self._json(HTTPStatus.OK, {"hosts": records, "generated_at": now_iso()})
            return

        match = re.fullmatch(r"/api/state/([0-9a-f-]{17})", path)
        if match:
            mac = match.group(1)
            if not MAC_HYPHEN_RE.match(mac):
                self._json(HTTPStatus.BAD_REQUEST, {"error": "malformed MAC"})
                return
            with _LOCK:
                self._json(HTTPStatus.OK, read_state(mac))
            return

        match = re.fullmatch(r"/state/([0-9a-f-]{17})\.ipxe", path)
        if match:
            mac = match.group(1)
            if not MAC_HYPHEN_RE.match(mac):
                self._send(HTTPStatus.BAD_REQUEST, b"#!ipxe\necho malformed MAC\nexit 1\n")
                return
            status, script = dispatch(mac)
            self._send(status, script.encode("utf-8"))
            return

        # iPXE reports progress with GET because imgfetch cannot POST.
        if path == "/api/log":
            LOG.info("ipxe event: %s", urlparse(self.path).query or "(no query)")
            self._send(HTTPStatus.OK, b"#!ipxe\nexit 0\n")
            return

        self._json(HTTPStatus.NOT_FOUND, {"error": "no such endpoint", "path": path})

    def do_HEAD(self) -> None:  # noqa: N802
        self.do_GET()

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path

        if not self._authorised():
            LOG.warning("rejected unauthenticated POST to %s from %s", path, self.client_address[0])
            self._json(HTTPStatus.UNAUTHORIZED, {"error": "missing or invalid X-Forge-Token"})
            return

        try:
            body = self._read_body()
        except ValueError as exc:
            self._json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": str(exc)})
            return

        match = re.fullmatch(r"/api/state/([0-9a-f-]{17})", path)
        if match:
            mac = match.group(1)
            if not MAC_HYPHEN_RE.match(mac):
                self._json(HTTPStatus.BAD_REQUEST, {"error": "malformed MAC"})
                return
            try:
                payload = json.loads(body or b"{}")
            except json.JSONDecodeError as exc:
                self._json(HTTPStatus.BAD_REQUEST, {"error": f"invalid JSON: {exc}"})
                return

            new_state = str(payload.get("state", "")).strip()
            source = str(payload.get("source", "api"))[:64]
            detail = str(payload.get("detail", ""))[:512]

            with _LOCK:
                record = read_state(mac)
                record["mac"] = mac
                if payload.get("host"):
                    record["host"] = str(payload["host"])[:64]
                ok, message = transition(record, new_state, source=source, detail=detail)
                if not ok:
                    LOG.warning("rejected %s -> %s for %s: %s", record.get("state"), new_state, mac, message)
                    self._json(HTTPStatus.CONFLICT, {"error": message, "current": record.get("state")})
                    return
                write_state(record)
            LOG.info("%s -> %s (source=%s)", mac, new_state, source)
            self._json(HTTPStatus.OK, {"result": "ok", "mac": mac, "state": new_state})
            return

        match = re.fullmatch(r"/api/log/([^/]+)/([^/]+)", path)
        if match:
            host_name, log_name = match.group(1), match.group(2)
            if not SAFE_NAME_RE.match(host_name) or not SAFE_NAME_RE.match(log_name):
                self._json(HTTPStatus.BAD_REQUEST, {"error": "unsafe host or log name"})
                return
            target_dir = LOG_DIR / "guests" / host_name
            target_dir.mkdir(parents=True, exist_ok=True)
            target = target_dir / log_name
            # Resolve and re-check: defence in depth against traversal.
            if not str(target.resolve()).startswith(str((LOG_DIR / "guests").resolve())):
                self._json(HTTPStatus.BAD_REQUEST, {"error": "path escapes the log directory"})
                return
            target.write_bytes(body)
            LOG.info("stored %d bytes of %s for %s", len(body), log_name, host_name)
            self._json(HTTPStatus.OK, {"result": "stored", "path": str(target), "bytes": len(body)})
            return

        self._json(HTTPStatus.NOT_FOUND, {"error": "no such endpoint", "path": path})


def main() -> int:
    logging.basicConfig(
        level=os.environ.get("FORGE_LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)-7s %(name)s %(message)s",
        stream=sys.stdout,
    )
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    server.daemon_threads = True

    def shutdown(signum, _frame):
        LOG.info("signal %s received, shutting down", signum)
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    LOG.info(
        "forge-state listening on %s:%s (state=%s, registry=%s, max_attempts=%d, auth=%s)",
        LISTEN_HOST, LISTEN_PORT, STATE_DIR, REGISTRY_PATH, MAX_ATTEMPTS,
        "token" if SHARED_TOKEN else "none",
    )
    server.serve_forever()
    server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
