# `compose/` — the FORGE-AI control plane

Everything in this directory runs on the KVM host as Docker containers.
It is brought up by `make deploy-control-plane`, never by a bare
`docker compose up` (the Makefile performs pre-flight checks that the
compose file cannot).

| Service | Image / build | Purpose | Published on |
|---|---|---|---|
| `database` | `postgres:16.4-alpine3.20` | One role + database per application | internal only |
| `gitea` | `gitea/gitea:1.22.6-rootless` | Internal GitOps repository | SSH on `${BIND_ADDRESS}:2222`, HTTP via `proxy` |
| `semaphore` | `semaphoreui/semaphore:v2.10.34` | Ansible workflow engine and audit trail | via `proxy` |
| `proxy` | `nginx:1.27.2-alpine3.20` | TLS termination for Gitea and Semaphore | `${BIND_ADDRESS}:8081`, `:8443` |
| `bootsrv` | `nginx:1.27.2-alpine3.20` | Boot artefacts, seeds, answer files | `192.168.250.1:8080` |
| `state` | `./state-service` | iPXE dispatch, lifecycle state, loop guard | via `bootsrv` |
| `webhook` | `./webhook` | HMAC-validated Gitea → Semaphore trigger | internal only |
| `winmedia` | `./samba` | Read-only SMB export of Windows media | `192.168.250.1:445` (profile `windows`) |

## Sub-directories

- `state-service/` — the provisioning state service (`app.py`) and its
  `Dockerfile`. Standard library only; see the module docstring for the
  state machine.
- `webhook/` — the Gitea webhook receiver (`app.py`) and its
  `Dockerfile`. Verifies HMAC-SHA256 before parsing anything.
- `samba/` — read-only SMB export used by WinPE to reach `install.wim`.
  Built rather than pulled so its configuration is auditable in-repo.
- `nginx/` — `proxy.conf` for the control-plane proxy and `tls/` for the
  certificate pair (git-ignored, generated at bootstrap).
- `database/init/` — first-boot SQL that creates the per-application
  roles and databases.

## The `windows` profile

`winmedia` only starts when the Windows target is in play:

```bash
docker compose --env-file compose/.env -f compose/docker-compose.yml \
  --profile windows up -d
```

`make deploy-control-plane` adds the profile automatically when
`media.windows.iso_path` is set in `config/poc.yml`.

## Ordering constraint

`bootsrv` and `winmedia` bind to `192.168.250.1`, the libvirt bridge.
That address does not exist until the provisioning network is defined,
so the network must be created **before** the stack starts.
`make bootstrap` does this in the right order; `make deploy-control-plane`
fails with a clear message if the bridge is missing.

## Logs

```bash
docker compose --env-file compose/.env -f compose/docker-compose.yml logs -f state
docker compose --env-file compose/.env -f compose/docker-compose.yml ps
```

JSON file logging is capped at 10 MB × 5 files per container. Host-side
logs (dnsmasq, nginx access logs, guest installer logs) live under
`/srv/forge-ai/logs/`.
