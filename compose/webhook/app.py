#!/usr/bin/env python3
"""FORGE-AI webhook receiver: Gitea push events -> Semaphore task runs.

Why this exists
---------------

Semaphore can be triggered by its own integrations, but the PoC needs
three things a generic integration does not give:

* **HMAC verification before anything else happens.** Gitea signs the
  request body with HMAC-SHA256 (``X-Gitea-Signature``). An unverified
  webhook is an unauthenticated remote "please deploy my branch".
* **Branch policy.** Only the configured default branch is allowed to
  start a deployment. A push to a feature branch is acknowledged and
  ignored, which is what keeps unreviewed code out of the
  infrastructure.
* **Template routing.** Different paths in the repository map to
  different Semaphore templates -- a docs-only commit should not
  reprovision two virtual machines.

Everything is standard library so the container has no dependency
surface beyond the pinned Python base image.
"""

from __future__ import annotations

import fnmatch
import hashlib
import hmac
import json
import logging
import os
import re
import signal
import sys
import threading
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

LOG = logging.getLogger("forge-webhook")

WEBHOOK_SECRET = os.environ.get("FORGE_WEBHOOK_SECRET", "")
SEMAPHORE_URL = os.environ.get("SEMAPHORE_URL", "http://semaphore:3000").rstrip("/")
SEMAPHORE_TOKEN = os.environ.get("SEMAPHORE_API_TOKEN", "")
SEMAPHORE_PROJECT_ID = os.environ.get("SEMAPHORE_PROJECT_ID", "")
ALLOWED_BRANCH = os.environ.get("FORGE_ALLOWED_BRANCH", "main")
LISTEN_HOST = os.environ.get("FORGE_LISTEN_HOST", "0.0.0.0")  # noqa: S104
LISTEN_PORT = int(os.environ.get("FORGE_LISTEN_PORT", "8000"))
DRY_RUN = os.environ.get("FORGE_WEBHOOK_DRY_RUN", "false").lower() in {"1", "true", "yes"}
MAX_BODY_BYTES = 2 * 1024 * 1024

# path glob -> Semaphore template id. First match wins; the order is
# significant, so this is a list of pairs rather than a dict.
# Configured as JSON in FORGE_TEMPLATE_ROUTES, for example:
#   [["docs/**", null], ["ansible/**", 7], ["**", 7]]
# A null template id means "acknowledge, run nothing".
DEFAULT_ROUTES = [
    ["docs/**", None],
    ["*.md", None],
    ["LICENSE", None],
    ["**", None],
]


def load_routes() -> list[list]:
    raw = os.environ.get("FORGE_TEMPLATE_ROUTES", "").strip()
    if not raw:
        return DEFAULT_ROUTES
    try:
        routes = json.loads(raw)
    except json.JSONDecodeError as exc:
        LOG.error("FORGE_TEMPLATE_ROUTES is not valid JSON (%s); falling back to defaults", exc)
        return DEFAULT_ROUTES
    if not isinstance(routes, list):
        LOG.error("FORGE_TEMPLATE_ROUTES must be a JSON array; falling back to defaults")
        return DEFAULT_ROUTES
    return routes


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def verify_signature(body: bytes, presented: str) -> bool:
    """Constant-time HMAC-SHA256 check of the Gitea signature header."""
    if not WEBHOOK_SECRET:
        LOG.error("FORGE_WEBHOOK_SECRET is empty: refusing every webhook")
        return False
    if not presented:
        return False
    expected = hmac.new(WEBHOOK_SECRET.encode("utf-8"), body, hashlib.sha256).hexdigest()
    # Gitea sends a bare hex digest; GitHub-style "sha256=" prefixes are
    # tolerated so the same endpoint can be pointed at either.
    candidate = presented.split("=", 1)[-1].strip().lower()
    return hmac.compare_digest(expected, candidate)


def changed_paths(payload: dict) -> list[str]:
    paths: set[str] = set()
    for commit in payload.get("commits", []) or []:
        for key in ("added", "removed", "modified"):
            paths.update(commit.get(key, []) or [])
    return sorted(paths)


def select_template(paths: list[str], routes: list[list]) -> tuple[int | None, str]:
    """Return (template_id, reason) for the first route that matches."""
    if not paths:
        # A push with no file list (a tag, or a squashed force push) is
        # treated as "everything changed" rather than silently skipped.
        for pattern, template in routes:
            if pattern == "**":
                return template, "no file list in payload; matched catch-all route"
        return None, "no file list and no catch-all route"

    for pattern, template in routes:
        matched = [p for p in paths if fnmatch.fnmatch(p, pattern) or (pattern.endswith("/**") and p.startswith(pattern[:-2]))]
        if pattern == "**":
            matched = paths
        if not matched:
            continue
        # A route only wins if EVERY changed path matches it; otherwise a
        # commit touching docs plus ansible/ would be routed as docs-only.
        if len(matched) == len(paths):
            return template, f"all {len(paths)} changed path(s) matched '{pattern}'"
    for pattern, template in routes:
        if pattern == "**":
            return template, "mixed changes; matched catch-all route"
    return None, "no route matched"


def trigger_semaphore(template_id: int, payload: dict) -> tuple[bool, str]:
    if not SEMAPHORE_TOKEN or not SEMAPHORE_PROJECT_ID:
        return False, "SEMAPHORE_API_TOKEN or SEMAPHORE_PROJECT_ID is not configured"

    commit = (payload.get("head_commit") or {}).get("id") or payload.get("after") or "unknown"
    pusher = (payload.get("pusher") or {}).get("username") or "unknown"

    body = json.dumps({
        "template_id": int(template_id),
        "debug": False,
        "dry_run": False,
        "diff": False,
        "message": f"gitea push {commit[:12]} by {pusher}",
        "environment": json.dumps({
            "forge_trigger": "gitea-webhook",
            "forge_git_commit": commit,
            "forge_pusher": pusher,
            "forge_received_at": now_iso(),
        }),
    }).encode("utf-8")

    url = f"{SEMAPHORE_URL}/api/project/{SEMAPHORE_PROJECT_ID}/tasks"
    request = urllib.request.Request(url, data=body, method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("Authorization", f"Bearer {SEMAPHORE_TOKEN}")

    if DRY_RUN:
        LOG.info("[dry-run] would POST %s template=%s commit=%s", url, template_id, commit[:12])
        return True, "dry-run"

    try:
        with urllib.request.urlopen(request, timeout=30) as response:  # noqa: S310 - fixed internal URL
            text = response.read().decode("utf-8", "replace")
            LOG.info("semaphore accepted template %s (HTTP %s)", template_id, response.status)
            return True, text[:512]
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:512]
        LOG.error("semaphore rejected template %s: HTTP %s %s", template_id, exc.code, detail)
        return False, f"HTTP {exc.code}: {detail}"
    except (urllib.error.URLError, OSError) as exc:
        LOG.error("semaphore unreachable at %s: %s", url, exc)
        return False, f"unreachable: {exc}"


class Handler(BaseHTTPRequestHandler):
    server_version = "forge-webhook/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        LOG.info("%s - %s", self.client_address[0], fmt % args)

    def _json(self, status: int, payload: dict) -> None:
        body = (json.dumps(payload, indent=2) + "\n").encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if urlparse(self.path).path in ("/healthz", "/"):
            self._json(HTTPStatus.OK, {
                "status": "ok",
                "component": "forge-webhook",
                "allowed_branch": ALLOWED_BRANCH,
                "semaphore": SEMAPHORE_URL,
                "signature_required": bool(WEBHOOK_SECRET),
                "dry_run": DRY_RUN,
            })
            return
        self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path not in ("/webhook", "/webhook/gitea"):
            self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._json(HTTPStatus.BAD_REQUEST, {"error": "bad Content-Length"})
            return
        if length > MAX_BODY_BYTES:
            self._json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "payload too large"})
            return
        body = self.rfile.read(length) if length else b""

        # ---- 1. authenticity, before parsing anything -----------------
        signature = self.headers.get("X-Gitea-Signature") or self.headers.get("X-Hub-Signature-256", "")
        if not verify_signature(body, signature):
            LOG.warning("rejected webhook from %s: bad or missing HMAC signature", self.client_address[0])
            self._json(HTTPStatus.UNAUTHORIZED, {"error": "signature verification failed"})
            return

        event = self.headers.get("X-Gitea-Event", self.headers.get("X-GitHub-Event", "push"))
        try:
            payload = json.loads(body or b"{}")
        except json.JSONDecodeError as exc:
            self._json(HTTPStatus.BAD_REQUEST, {"error": f"invalid JSON: {exc}"})
            return

        if event != "push":
            LOG.info("ignoring '%s' event", event)
            self._json(HTTPStatus.ACCEPTED, {"result": "ignored", "reason": f"event '{event}' is not handled"})
            return

        # ---- 2. branch policy -----------------------------------------
        ref = payload.get("ref", "")
        branch = re.sub(r"^refs/heads/", "", ref)
        if branch != ALLOWED_BRANCH:
            LOG.info("ignoring push to '%s' (only '%s' deploys)", branch or ref, ALLOWED_BRANCH)
            self._json(HTTPStatus.ACCEPTED, {
                "result": "ignored",
                "reason": f"branch '{branch or ref}' is not the deployment branch '{ALLOWED_BRANCH}'",
            })
            return

        # ---- 3. routing ------------------------------------------------
        paths = changed_paths(payload)
        template_id, reason = select_template(paths, load_routes())
        LOG.info("push to %s: %d changed path(s); %s -> template %s", branch, len(paths), reason, template_id)

        if template_id is None:
            self._json(HTTPStatus.ACCEPTED, {
                "result": "ignored", "reason": reason, "changed_paths": len(paths),
            })
            return

        ok, detail = trigger_semaphore(template_id, payload)
        self._json(HTTPStatus.OK if ok else HTTPStatus.BAD_GATEWAY, {
            "result": "triggered" if ok else "failed",
            "template_id": template_id,
            "reason": reason,
            "detail": detail,
        })


def main() -> int:
    logging.basicConfig(
        level=os.environ.get("FORGE_LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)-7s %(name)s %(message)s",
        stream=sys.stdout,
    )
    if not WEBHOOK_SECRET:
        LOG.warning(
            "FORGE_WEBHOOK_SECRET is empty. Every webhook will be rejected. "
            "Run bootstrap/create-secrets.sh and restart this container."
        )

    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    server.daemon_threads = True

    def shutdown(signum, _frame):
        LOG.info("signal %s received, shutting down", signum)
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    LOG.info("forge-webhook listening on %s:%s (branch=%s, dry_run=%s)", LISTEN_HOST, LISTEN_PORT, ALLOWED_BRANCH, DRY_RUN)
    server.serve_forever()
    server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
