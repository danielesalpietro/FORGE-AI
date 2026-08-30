# `tests/integration/`

Tests that need a **live control plane** or **provisioned targets**.
They skip themselves when the endpoints are not answering, so the same
`pytest` invocation works in CI and on a KVM host.

```bash
# after: make deploy-control-plane
pytest tests/integration -m integration -v
```

## What is here

| File | Needs | Verifies |
|---|---|---|
| `test_control_plane.py` | `make deploy-control-plane` | Boot server and state service health, per-host dispatch, cache headers, token enforcement, and that the seeds are served at the exact URL the installer requests |

## What is deliberately *not* here

Anything that needs a booted virtual machine. That is
`scripts/smoke-test.sh`, which runs against real targets and reports in
both human and JUnit form:

```bash
./scripts/smoke-test.sh --junit results.xml
```

The split is intentional. These tests answer "is the control plane
correct?" in seconds and can run on every change. The smoke test answers
"did the machines come out right?" and needs a 30-minute deployment
first.

## Running the full end-to-end path

`docs/DEMO-RUNBOOK.md` is the complete sequence. In short:

```bash
make check && make bootstrap
make prepare-media
make provision
make validate            # includes the idempotence check
./scripts/smoke-test.sh
```
