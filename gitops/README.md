# GitOps: Argo CD Layer (Phases 4-9)

Converts the working script's Phase 4-9 into an Argo CD **App-of-Apps**.
Ansible converges the host and hands off to `argocd` (last role in
`site.yml`), which installs Argo CD and applies `bootstrap/root-app.yaml`.
From there, everything under `gitops/apps/` is owned and reconciled by
Argo CD, pulling from this same git repo.

## Structure

```
gitops/
├── bootstrap/
│   └── root-app.yaml           # reference copy of what the argocd Ansible role applies
├── apps/                        # one Application per component, sync-wave ordered
│   ├── 00-metallb.yaml
│   ├── 00-envoy-gateway.yaml
│   ├── 00-ingress-nginx.yaml
│   ├── 00-node-labels.yaml
│   ├── 01-metallb-config.yaml       # IPAddressPool/L2Advertisement
│   ├── 01-envoy-gateway-config.yaml # EnvoyProxy/Gateway
│   ├── 01-storage-defaults.yaml     # unsets local-path as default StorageClass
│   ├── 01-rook-ceph-operator.yaml
│   ├── 02-rook-ceph-cluster.yaml
│   ├── 02-rabbitmq.yaml / 02-mariadb.yaml / 02-memcached.yaml
│   ├── 03-ceph-adapter-rook.yaml / 03-keystone.yaml
│   ├── 04-heat.yaml / 04-glance.yaml / 04-cinder.yaml
│   ├── 05-openvswitch.yaml / 05-libvirt.yaml / 05-placement.yaml
│   ├── 06-nova.yaml
│   ├── 07-neutron.yaml
│   ├── 08-horizon.yaml
│   └── 09-ingress-resources.yaml    # Horizon + noVNC Ingress objects
├── manifests/                   # raw YAML for the Applications above that aren't Helm charts
│   ├── node-labels/
│   ├── metallb-config/
│   ├── envoy-gateway-config/
│   ├── storage-defaults/
│   └── ingress-resources/
└── values/                      # our own overrides layered on top of upstream ones
    ├── mariadb-local.yaml
    ├── glance-local.yaml
    ├── neutron-local.yaml
    └── nova-local.yaml
```

## Why App-of-Apps, not an ApplicationSet list generator

The OpenStack chart set (13 near-identical charts) is a textbook
ApplicationSet use case, and I considered generating those 13 files from
a list generator instead of committing them individually. I didn't,
because **sync-waves only gate ordering across resources belonging to one
Application's sync** — child Applications reconciled by root-app's single
sync respect each other's `sync-wave` annotation (this is what makes
rook-ceph-cluster wait for rook-ceph-operator to be Healthy first).
Applications created by an ApplicationSet are reconciled by the
ApplicationSet controller independently of one another, so wave numbers
on them wouldn't actually be enforced — you'd get the file count savings
but lose the dependency ordering that used to be `helm osh
wait-for-pods` between phases in the bash script. Plain files won.

## Sync-wave plan (mirrors the script's phase dependencies)

| Wave | Apps | Why here |
|---|---|---|
| 0 | metallb, envoy-gateway, ingress-nginx, node-labels | No dependencies |
| 1 | metallb-config, envoy-gateway-config, storage-defaults, rook-ceph-operator | CRs need their controllers' webhooks up (retry/backoff handles the remaining race — see below); storage-defaults just needs to land before any chart creates a PVC; operator needs no labels |
| 2 | rook-ceph-cluster, rabbitmq, mariadb, memcached | Cluster needs operator; core infra has no ceph/keystone dependency |
| 3 | ceph-adapter-rook, keystone | Needs mon quorum / nothing blocking |
| 4 | heat, glance, cinder | Cinder needs a reachable mon (wave 2/3) and a default StorageClass (wave 1) |
| 5 | openvswitch, libvirt, placement | |
| 6 | nova | Needs placement |
| 7 | neutron | Needs nova, openvswitch |
| 8 | horizon | Last chart |
| 9 | ingress-resources | References horizon-int/nova-novncproxy Services which must already exist |

Note on `node-labels` (wave 0): `ceph-rook.sh`'s own `cephClusterSpec`
uses `storage.useAllNodes: true` with no `placement`/`nodeAffinity`
block, so the `ceph-mon`/`ceph-osd`/`ceph-mds`/`ceph-rgw` labels this Job
applies aren't actually consumed by `rook-ceph-cluster` as written —
Rook schedules onto every node regardless. They're kept here because (a)
they're harmless, (b) `ceph-adapter-rook`'s docs show it *does* key off
`openstack-control-plane=enabled` for its own jobs, and (c) they're a
reasonable hook if you ever move to per-role node placement on a
multi-node cluster. Just don't assume today's single-node Ceph
scheduling depends on them.

## Replacing the script's imperative retry/patch hacks

- **Webhook-not-ready races** (`for i in {1..10}; do kubectl apply || sleep 5`
  for MetalLB/Envoy CRDs): replaced with Argo CD's native
  `syncPolicy.retry` (backoff) on `metallb-config` /
  `envoy-gateway-config`.
- **CephCluster deploy-then-patch** (background watcher patching
  `mon.count`/`storage.deviceFilter` after the fact): replaced by
  templating `cephClusterSpec` directly in `02-rook-ceph-cluster.yaml`'s
  Helm values, merging `ceph-rook.sh`'s base config with what the patch
  used to change (mon/mgr count 3→1, `devices` list → `deviceFilter`
  regex) — no race, no forced pod deletion needed.
- **Duplicate default StorageClass** (`kubectl patch storageclass
  local-path ...` to unset it once Rook's `general` class exists):
  ported as-is to `manifests/storage-defaults/local-path.yaml`, wave 1
  (ahead of `rook-ceph-cluster` creating `general`, and well ahead of
  any chart requesting a PVC).
- **Node labeling** (`kubectl label` in bash): a `Job` (wave 0,
  `manifests/node-labels/`) that Argo CD's built-in Job health check
  treats as Healthy only once `Complete`, so later waves correctly wait
  on it.
- **Cinder's `mon_host`** (`kubectl get pods -o jsonpath=...podIP`, a
  pod IP that goes stale on reschedule): dropped entirely, no
  replacement needed. `ceph-adapter-rook`'s `conf.ceph.global.mon_host`
  already defaults to auto-discovery (its `job_namespace_client_ceph_config`
  job resolves it and writes a shared `ceph-etc` ConfigMap into the
  `openstack` namespace), which `cinder` (and `nova`/`libvirt`/`glance`)
  consume on their own — confirmed against the current
  `ceph-adapter-rook` chart docs. The original script's `sed`-into-
  `helm show values` hack was working around something this version of
  openstack-helm now automates.

## Known gaps — please read before relying on this

1. **`ceph-rook.sh` — now ported directly, confirmed against the actual
   script.** `01-rook-ceph-operator.yaml` and `02-rook-ceph-cluster.yaml`
   mirror its `/tmp/rook.yaml` and `/tmp/ceph.yaml` values line-for-line
   (Rook pinned to `v1.19.3`, `allowLoopDevices: true`, the
   `mon_allow_pool_size_one` configOverride, `general`/`ceph-bucket`
   StorageClasses, etc.), with only the two deviations already called
   out above (mon/mgr count, deviceFilter) — both of which the working
   script itself also deviates from via its Phase 5 patch, so this
   matches the script's actual end state, not just its initial `helm
   install`. Not ported: the script's polling loops waiting for
   mon/RGW pods and printing `ceph -s`/`ceph osd pool ls` along the way
   — that's operational visibility for a human watching a terminal, and
   has no GitOps equivalent; use `argocd app get rook-ceph-cluster` or
   `kubectl exec -n ceph deploy/rook-ceph-tools -- ceph -s` instead.

2. **~~Host-side / GitOps conflict on `placement`~~ — FIXED, and confirmed
   on a real reboot.** This was originally flagged as a theoretical
   gap, then downgraded to "narrow but real, not yet observed," and has
   now actually happened: a reboot on Aug 2, 2026 hit exactly the
   predicted failure —
   `Error: open .../overrides/placement/2025.1-ubuntu_noble.yaml: no
   such file or directory` — confirming `overrides/` genuinely doesn't
   exist on this (rebuilt, fresh-VM) host, unlike the original host
   this was first diagnosed on.

   Fixed by removing just the broken block (`helm upgrade placement
   ...`) from `openstack-network-plumbing.sh.j2`, not the whole
   recovery routine — the MariaDB tc.log/grastate cleanup, the
   `kubectl delete job placement-db-init placement-db-sync`, the wait
   for a fresh `placement-db-sync`, and the Placement API/Nova
   conductor+scheduler pod recycling afterward are all still there and
   still correct. The only change: instead of the script trying (and
   failing) to recreate the Jobs itself via a broken `helm upgrade`,
   it now just deletes them and lets Argo CD's `selfHeal: true` (which
   already owns `placement` declaratively, including the
   `placement-hook-jobs` workaround for argo-cd#23555) recreate them
   correctly on its own next reconcile. Confirmed this is the right
   shape of fix, not just removing the symptom.

3. **Secrets**: per your call, this layer assumes plain Kubernetes
   Secrets already exist in-cluster before Argo CD needs them
   (Keystone admin password, `clouds.yaml`) — created out-of-band, not
   committed to git, not managed by Argo CD. `keystone` (wave 3) and any
   chart consuming the admin credential will need that secret name
   wired into its values once you decide what it's called; I haven't
   guessed at one to avoid inventing an interface you didn't ask for.

4. **CephBlockPool/CephObjectStore replica size**: `size: 1` everywhere,
   straight from `ceph-rook.sh` itself (it's not a lab-only shortcut I
   added — the script's own `configOverride` requires it via
   `mon_allow_pool_size_one`). Still worth flagging: with one OSD, one
   disk failure loses all data in this cluster. Fine for a lab; revisit
   before treating anything here as durable.

5. **`local-path` StorageClass fields must match your k3s version
   exactly.** `provisioner`, and on most Kubernetes versions
   `volumeBindingMode`, are immutable on an existing StorageClass —
   `manifests/storage-defaults/local-path.yaml` assumes k3s's stock
   `rancher.io/local-path` / `WaitForFirstConsumer` defaults. If your
   k3s version ships something different, the apply will fail with an
   immutable-field error rather than silently doing the wrong thing —
   check with `kubectl get storageclass local-path -o yaml` first if so.

6. **Node labels — fixed to match the script exactly.** An earlier
   version of `manifests/node-labels/job.yaml` labeled every node with
   `ceph-mon`/`ceph-osd`/`ceph-mds`/`ceph-rgw`; the script only labels
   the *first* node with those (all nodes get
   `openstack-control-plane`/`openstack-compute-node`/`openvswitch`).
   Fixed to match. No functional difference today (single-node
   cluster) but would have mattered the moment this becomes multi-node.

7. **Wave 5 (`openvswitch`, `libvirt`, `placement`) syncs in parallel;
   the script runs them serially with only a partial wait.** The script
   does `helm osh wait-for-pods openstack` after `openvswitch`, but
   *not* after `libvirt`, `placement`, or `nova` — those three fire
   back-to-back with no wait between them, and the next real
   synchronization point is `neutron`'s wait-for-pods, which ends up
   validating all of them at once. This layer is stricter: `libvirt`/
   `placement` sync together (wave 5) but `nova` (wave 6) and `neutron`
   (wave 7) each wait for the previous wave to be fully Healthy first.
   That's a deliberate improvement, not a literal port — flagging it so
   it doesn't look like an oversight if you're diffing timing against
   the script.

8. **`helm-workspace` role's git clone + plugin install are now mostly
   vestigial for chart deployment** — Argo CD fetches
   `openstack-helm.git` itself per-Application and doesn't use the
   `openstack-helm-plugin` (`helm osh ...`) at all; I replaced its
   override-fetching with static git-source references instead. That
   role still needs to keep running for now, though: the (broken, see
   #2) `openstack-network-plumbing.sh.j2` still points at
   `{{ workspace_dir }}/openstack-helm/placement`. Once #2 is fixed,
   revisit whether `helm-workspace` is worth keeping at all.

9. **Unverified: subchart dependency resolution for `helm dependency
    build`.** Several openstack-helm charts (mariadb, memcached,
    rabbitmq, etc.) depend on a shared `helm-toolkit` chart. The
    working script runs `helm repo add openstack-helm
    https://tarballs.opendev.org/openstack/openstack-helm` early
    (Phase 3) even though Phase 7's `helm upgrade` calls all use local
    filesystem paths — the likely reason is that each chart's
    `Chart.yaml` declares `helm-toolkit` as a dependency resolved via
    that repository URL, and `helm dependency build` needs it
    reachable. Argo CD's repo-server runs the equivalent of `helm
    dependency build` automatically against the URL in each chart's
    `Chart.yaml` directly (it doesn't need a separately-registered repo
    alias for that to work) — so this is likely a non-issue, but I
    haven't inspected `Chart.yaml` in the actual repo to confirm the
    dependency's `repository:` field points at a real, publicly
    fetchable URL rather than something like `http://localhost:8879/charts`
    (an old openstack-helm build-time convention). If the very first
    sync of `02-mariadb.yaml`/`02-rabbitmq.yaml` fails with a dependency
    resolution error, this is where to look first.
10. **`repoURL`/`targetRevision` placeholders**: every Application that
   references this repo itself (root-app, node-labels, metallb-config,
   envoy-gateway-config, ingress-resources, and the `$local` source on
   mariadb/glance/neutron/nova/cinder) uses `{{ GITOPS_REPO_URL }}` /
   `{{ GITOPS_REPO_REVISION }}` as literal text in the committed YAML —
   these are **not** Ansible/Jinja templates that render on their own;
   only the Ansible role's `root-app.yaml.j2` copy actually substitutes
   them. Before committing this repo, either replace those placeholders
   with your real repo URL directly, or template the whole `gitops/`
   tree the same way if you want it parameterized too.
