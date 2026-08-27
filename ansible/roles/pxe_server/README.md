# `pxe_server`

DHCP, DNS and TFTP for the provisioning segment, as a **dedicated
dnsmasq instance** bound only to the libvirt bridge.

## Why a dedicated instance

A drop-in under `/etc/dnsmasq.d/` would change the behaviour of
whatever dnsmasq the host already runs — on a desktop, that is often
the one NetworkManager owns. That is precisely the "PXE DHCP on a
production LAN" accident this project warns about. A dedicated unit
also means teardown can stop DHCP without touching host networking.

The role stops and disables the packaged `dnsmasq` service and says so
in the run output, so the change is never silent.

## The boot chain, and why it does not loop

`ansible/templates/dnsmasq/provisioning.conf.j2` encodes the whole
decision:

```
dhcp-match=set:efi64,option:client-arch,9      # arch detection (RFC 4578)
dhcp-match=set:ipxe,175                        # iPXE encapsulated options
dhcp-userclass=set:ipxe,iPXE                   # iPXE user-class

dhcp-boot=tag:efi64,tag:!ipxe,ipxe.efi         # firmware -> give it iPXE
dhcp-boot=tag:ipxe,http://.../boot/boot.ipxe   # iPXE     -> give it a script
```

Every "hand over a binary" rule carries `tag:!ipxe`. iPXE can therefore
never be told to load iPXE again, which is the classic chainload loop.

## Transport split

| Transport | Carries | Why |
|---|---|---|
| TFTP (udp/69) | `undionly.kpxe`, `ipxe.efi` — tens of KB | The only thing a firmware PXE ROM can speak |
| HTTP (tcp/8080) | Everything else — kernels, initrds, WIMs, the Ubuntu ISO | TFTP's lock-step ACK makes multi-MB transfers slow and fragile |

## Configuration is validated before it is applied

The template uses `validate: dnsmasq --test --conf-file=%s`, and the
systemd unit repeats the test in `ExecStartPre`. A dnsmasq that refuses
to start is indistinguishable, from a client's point of view, from a
network with no DHCP at all — so a bad file must never reach a restart.

## Verification

The role asserts that something is listening on udp/67 and udp/69
before declaring success, with the diagnostic commands in the failure
message.

```bash
sudo systemctl status forge-dnsmasq
sudo journalctl -u forge-dnsmasq -f
sudo tcpdump -i virbr-forge -n 'udp port 67 or udp port 68'
```

## Tags

`provisioning`, `network`, `media`, `validation`
