# Ansible: Host Bootstrap Layer

Converts **Phases 1–3** of the working deployment script (`Working_Script.txt`)
into an idempotent Ansible playbook: kernel tuning, the persistence systemd
units (`openstack-host-deps`, `openstack-network-plumbing`, `clean-shutdown`),
k3s, Docker, and the openstack-helm workspace clone.

**Not included here (by design):** chart deployment (Phases 4–9 — MetalLB,
Envoy Gateway, Rook-Ceph, and the OpenStack-Helm chart set itself). That layer
is being migrated to Argo CD / GitOps instead of imperative `helm upgrade
--install` calls, so it lives in a separate `gitops/` directory once built.

## What changed vs. the original bash script

| Original script behavior | Ansible equivalent |
|---|---|
| `wipefs`/`dd` runs every execution | Only runs the first time the loop image is created (`stat` guard) |
| `tee -a` appends to `/etc/sysctl.conf` on every run | Dedicated `/etc/sysctl.d/99-openstack-helm.conf` drop-in, idempotent |
| `git clone ... || true` | `git` module with `update: false` — clone once, never clobber local edits |
| `iptables -I`/`-A` with no existence check | `-C` check before every rule insert, so reboots don't duplicate FORWARD/NAT rules |
| Manual `sleep`-based waits | `until`/`retries` loops against actual API/resource state |

## Usage

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml

# Point at your Infomaniak instance (Tailscale IP or public IP, as reachable)
export OPENSTACK_HOST_IP=100.113.247.85

# Path to the private key matching the authorized key on the host.
# Required — the inventory has no default and Ansible will fail with
# "Permission denied (publickey)" if this isn't set to a valid key.
export OPENSTACK_SSH_KEY=/path/to/your/private/key

ansible-playbook site.yml -i inventory/hosts.yml \
  -e gitops_repo_url=git@github.com:Speedylo/openstack_auto.git \
  -e gitops_repo_revision=main
```

If the playbook fails with `UNREACHABLE` / `Permission denied (publickey)`,
first isolate whether it's an Ansible problem or an SSH problem by
connecting manually with the same key and target:

```bash
ssh -i $OPENSTACK_SSH_KEY ubuntu@$OPENSTACK_HOST_IP
```

If manual SSH also fails, the issue is the key or username (confirm
`ansible_user: ubuntu` in `inventory/hosts.yml` actually matches the
login user for your Infomaniak image), not the playbook. If your key has
a passphrase, load it into `ssh-agent` first (`ssh-add $OPENSTACK_SSH_KEY`)
— non-interactive playbook runs can't prompt for it.

## Structure

```
ansible/
├── site.yml                        # entrypoint: host-prep → persistence → k3s → docker → workspace → cluster-dns
├── requirements.yml                 # kubernetes.core, community.general collections
├── inventory/
│   └── hosts.yml
└── roles/
    ├── host-prep/                   # kernel tuning, DNS, systemd timeouts
    ├── openstack-persistence/       # loop device, boot/shutdown systemd units, network plumbing
    ├── k3s/                         # k3s install, custom unit, kubeconfig
    ├── docker/                      # Docker install, group membership
    ├── helm-workspace/              # Helm repos, openstack-helm-plugin, git clone
    └── cluster-dns/                 # Phase 8: systemd-resolved → CoreDNS handoff (self-skipping)
```

## Known follow-ups (not yet addressed)

- **Secrets**: the `clouds.yaml` generation (Phase 8 in the original script)
  is intentionally not yet included here — it embeds a plaintext admin
  password. This needs a proper secrets story (Ansible Vault at minimum,
  or deferred entirely to the GitOps/Sealed-Secrets layer) before it's
  safe to template and commit.
- **DNS role toggle**: `host-prep` currently overwrites `/etc/resolv.conf`
  unconditionally. A `manage_dns_via_systemd_resolved` var stub exists but
  Phase 8's `systemd-resolved` forwarding config isn't ported yet.
- **Multi-host inventory**: written for a single node today; group/host
  vars would need to split out if this ever targets more than one host.

## Changelog

- Added a new `cluster-dns` role implementing Phase 8 (systemd-resolved
  → CoreDNS forwarding) from the working script, previously missing
  entirely — `host-prep`'s static DNS was only ever the Phase-1
  bootstrap state, not the final target. The role is self-skipping: it
  looks up the `kube-dns` service ClusterIP and no-ops cleanly with an
  explanatory message if CoreDNS isn't up yet (e.g. before Argo CD has
  synced the cluster), rather than failing or requiring a second,
  separately-remembered playbook invocation. Safe to leave in the
  default `site.yml` run permanently.
- Added `tailscale set --accept-dns=false` to `host-prep`, run before
  the static resolv.conf write. Root cause of "DNS settings not
  persisted": tailscaled continuously manages `/etc/resolv.conf` itself
  (MagicDNS) whenever `accept-dns` is enabled (its default), silently
  overwriting the static `8.8.8.8`/`1.1.1.1` config shortly after every
  write. Safe to disable since hostname resolution for Horizon/noVNC/
  instance access already goes through static `/etc/hosts` entries,
  not Tailscale MagicDNS. Confirmed via `cat /etc/resolv.conf` showing
  the Tailscale-generated file persisting instead of the static one.
- Added a `kubectl get namespace openstack` guard at the top of the
  background MariaDB/Placement recovery block in
  `openstack-network-plumbing.sh.j2`. Without it, every boot before
  OpenStack-Helm charts are deployed logs four `NotFound` errors
  (namespace, pod, Placement overrides file) and attempts a Helm
  upgrade against charts that don't exist yet — harmless but noisy,
  and a latent race risk once charts *are* deployed (recovery logic
  could fire before Kubernetes has scheduled MariaDB on a normal boot).
  Confirmed via reboot test against a fresh k3s host with no charts
  installed.
- Fixed task order in `host-prep`: "Ensure /etc/systemd/system.conf.d
  exists" now runs *before* "Cap global systemd manager start/stop
  timeouts". The original order tried to write
  `/etc/systemd/system.conf.d/timeout.conf` before the directory existed,
  failing with `Destination directory ... does not exist` on a real run.
- Added `ansible_ssh_private_key_file` (via `OPENSTACK_SSH_KEY` env var)
  to `inventory/hosts.yml`. The initial version relied on Ansible finding
  a usable key automatically (e.g. via `ssh-agent` or `~/.ssh/config`),
  which failed with `Permission denied (publickey)` against the real
  Infomaniak host — the key path now has to be passed explicitly.

## Next steps

1. Wire this into the `gitops/` Argo CD layer (Phases 4–9) as the second
   half of the pipeline — Ansible converges the host, Argo CD converges
   the cluster.
2. Add an Ansible Vault-encrypted `group_vars/openstack_hosts/vault.yml`
   for the Keystone admin password once the secrets story is decided.
3. Terraform for tenant resources (networks, instances, security groups)
   layers on top of both, once the OpenStack API is reliably reachable.
