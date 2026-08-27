# `ubuntu_autoinstall`

Renders and publishes the Subiquity NoCloud seed, then proves the
installer can actually fetch it.

## The trailing slash

The seed is served at:

```
http://192.168.250.1:8080/ubuntu/poc-ubuntu-01/
```

cloud-init appends the filenames to the `ds=nocloud;s=...` value
**verbatim**. Without the trailing slash the installer requests
`.../poc-ubuntu-01user-data`, gets a 404, finds no datasource and drops
to an interactive prompt — which on a headless VM is indistinguishable
from a hang. It is the most common Ubuntu PXE failure, and the reason
`ansible/templates/ipxe/host-ubuntu-install.ipxe.j2` builds the URL with
an explicit trailing slash.

## Secrets in the seed

The seed carries a **crypt(3) hash**, never a cleartext password. The
role asserts the hash format up front (`$y$`, `$6$`, `$5$`, `$2b$`),
because a cleartext value there would end up served over HTTP *and*
written into `/var/log/installer` on the target.

It also refuses to render when `security.ssh_authorized_keys` is empty:
the installed host disables SSH password authentication, so without a
key Ansible could never reach it. Failing here is much cheaper than
discovering it after a 20-minute install.

`tasks/purge.yml` removes the seed once the host reports `installed` and
leaves a `PURGED.txt` explaining how to re-render it. Controlled by
`security.purge_answer_files_after_install`.

## Validation

Two layers, both cheap and both worth it:

1. **Structural** — the rendered file is read back, parsed as YAML, and
   asserted to carry `version: 1`, the right hostname and username, an
   SSH key, a storage layout and late-commands.
2. **Transport** — an HTTP GET against the exact URL the installer will
   request. A 404 here is caught in seconds instead of twenty minutes.

## Tags

`provisioning`, `linux`, `security`, `validation`
