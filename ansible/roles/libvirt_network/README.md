# `libvirt_network`

Creates the isolated `gitops-provisioning` network and proves it is
usable before anything downstream depends on it.

## The one design decision that matters

The network XML (`ansible/templates/libvirt/network.xml.j2`) contains
**`<dns enable="no"/>` and no `<dhcp>` element**.

libvirt starts its own dnsmasq only when a network needs DHCP or DNS.
With neither, it creates the bridge and the NAT rules and stops. That
leaves DHCP entirely to the FORGE-AI dnsmasq instance
(`roles/pxe_server`), which needs `dhcp-match` on DHCP option 93 for
architecture detection and `dhcp-boot` with `tag:!ipxe` for chainload
loop prevention. libvirt's network XML can express neither.

The role verifies this after starting the network: if
`/var/lib/libvirt/dnsmasq/<network>.conf` exists, libvirt is serving
DHCP too and the play fails immediately rather than leaving two DHCP
servers to fight over the bridge.

## Force recreation

```bash
ansible-playbook playbooks/create-provisioning-network.yml \
  -e libvirt_network_force_recreate=true
```

This stops and undefines the existing network first, which
**disconnects every guest attached to it**. It is not the default for
that reason.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `libvirt_network_force_recreate` | `false` | Destroy and redefine an existing network |
| `libvirt_network_bridge_timeout` | `30` | Seconds to wait for the bridge device |

## Outputs

`forge_network_ready`, `forge_network_bridge` (cacheable facts).

## Troubleshooting

```bash
virsh net-list --all
virsh net-dumpxml gitops-provisioning
ip addr show dev virbr-forge
sudo tcpdump -i virbr-forge -n 'udp port 67 or udp port 68'
```

## Tags

`provisioning`, `network`, `validation`, `destroy`
