# Nuketown Cloud: Spec

**One-liner:** Define an AI agent in Nix. Push to main. It's running in the cloud.

## Problem

Today, nuketown agents run on physical machines you own. Deploying an agent
means editing a NixOS config, rebuilding, and switching — on a machine that
already exists. If you want an agent running 24/7 in the cloud, you're on your
own with Terraform, nixos-anywhere, and glue scripts.

The NixOS configuration already declares *everything* about the agent's
environment. The only thing missing is a thin translation layer that turns
that declaration into something a cluster can run.

## Vision

The NixOS config *is* the cloud API. No Terraform. No VM provisioning. No
separate IaC layer. You add `cloud.enable = true` to an agent, push to a
branch, and a cluster schedules it.

```
git push origin main
  |
  v
ArgoCD detects change
  → runs nuketown plugin (nix eval → k8s YAML)
  → diffs manifests vs cluster state
  → applies changes (create / update / delete pods)
  → nix-snapshotter pulls image layers (deduped from nix store)
  → agent is live
```

### The Vercel analogy

| Vercel | Nuketown Cloud |
|--------|---------------|
| Connect GitHub repo | ArgoCD watches repo |
| Framework detection → build | Nix evaluation → nix-snapshotter image |
| Provisions infra automatically | K8s schedules pod from manifests |
| Push to branch → deploy | Push to branch → ArgoCD sync |
| Preview deploys on PRs | ArgoCD preview environments |
| Dashboard for status | ArgoCD dashboard for agent status + logs |

## Why Kubernetes, Not VMs

The original spec proposed provisioning VMs via cloud APIs — a Hetzner backend,
then AWS, then GCE. Each provider needed: provision, resize, terminate, status,
list. That's Terraform with extra steps.

Kubernetes replaces all of that with one API:

- **No provider abstraction needed.** K8s API is the same everywhere —
  GKE, EKS, AKS, k3s on a VPS, k3s on your laptop.
- **No VM lifecycle management.** Pods schedule, restart, and migrate
  without custom code.
- **No custom reconciler.** ArgoCD already watches repos, diffs state,
  and converges. We just write a plugin that translates nix → YAML.
- **Orchestration features for free.** Vertical scaling, node affinity,
  preemptible capacity, health checks, rolling updates — things we'd
  never build for raw VMs.

### nix-snapshotter: the bridge

nix-snapshotter (already in the flake) runs NixOS closures as container
images with store-level deduplication. Each agent's environment is a
cached image layer. "Moving" an agent to a new node means pulling only
the diff — near-instant for agents sharing a nix store.

Combined with k8s scheduling, this gives us: many agents per node,
each with a unique identity, sharing nix store layers, booting in
seconds. The density properties that the original spec wanted from
Firecracker microVMs — but using standard k8s primitives.

## Cloud Metadata: NixOS Module Options

Minimal options under `nuketown.cloud`. The agent's *environment* is
already fully declared by the existing nuketown options. Cloud options
only declare *intent to run in a cluster*.

```nix
# machines/cloud-ada/configuration.nix
{ ... }:
{
  nuketown = {
    enable = true;
    agents.ada = {
      enable = true;
      role = "software";
      claudeCode.enable = true;
      persist = [ "projects" ".config/claude" ];
    };
  };

  nuketown.cloud = {
    enable = true;

    # Resource intent — the platform maps this to node selection.
    # No instance types. No provider-specific knobs.
    resources = "standard";  # "small", "standard", "large", "gpu"

    # Persistence is automatic for declared persist dirs.
    # Backend is the cluster's storage class.

    # Optional: scaling policy
    scaling = {
      # Agent can request more resources via chat approval
      maxResources = "large";
      # Idle agents downsize automatically
      idleTimeout = 3600;  # seconds before scaling down
    };
  };
}
```

### Minimal viable config

For the common case of "one agent in the cloud":

```nix
nuketown.cloud.enable = true;
```

That's 1 line on top of the existing nuketown agent config. The platform
picks sensible defaults for everything else.

### Resource tiers

Abstract away instance types entirely:

| Tier | Intent | Rough shape |
|------|--------|-------------|
| `small` | Idle / light tasks | 1 vCPU, 2GB RAM |
| `standard` | Normal development work | 2 vCPU, 4GB RAM |
| `large` | Builds, compilation | 4 vCPU, 8GB RAM |
| `gpu` | ML workloads | GPU node pool |

The reconciler maps tiers to k8s resource requests/limits. Cluster
operators configure node pools to satisfy them. Users never see
instance types.

## Orchestration UX

This is what k8s enables that VMs never could. The agent participates
in its own infrastructure decisions, the same way a colleague would.

### Resource scaling as conversation

```
ada: This rotorflight build is thrashing — I only have 2GB here.
     Mind if I move to something bigger?
josh: 👍
     *pod reschedules with 8GB, build resumes from nix cache*
ada: Back. Build's done, flashing now.
```

The mechanism:
1. Agent detects resource pressure (OOM warnings, CPU throttling)
2. Agent requests scale-up via chat (same UX as sudo approval)
3. Human approves (or auto-policy approves for known workloads)
4. Plugin updates pod resource requests
5. K8s reschedules pod on a suitable node
6. nix-snapshotter image is already cached — near-instant restart
7. Agent resumes from persisted state

Scaling *down* doesn't need approval — agents downsize automatically
after idle timeout. Same approval asymmetry as sudo: escalation needs
a human, de-escalation is free.

### Node migration

Agent moves between node pools based on task:

- **Idle**: spot/preemptible capacity (cheap)
- **Working**: on-demand standard nodes
- **Building**: beefy build nodes (maybe shared with CI)
- **GPU task**: GPU node pool

The agent doesn't manage this directly. The pod spec declares resource
requests, k8s handles scheduling. But the *conversation* about needing
more resources is natural and human-readable.

### Self-healing

K8s restarts crashed agents automatically. No monitoring to build.
The agent's state survives via persisted volumes. On restart:

1. Pod schedules on available node
2. PVC reattaches (persist dirs intact)
3. nix-snapshotter image loads from cache
4. Agent boots into clean environment + persisted state
5. Picks up where it left off

## Persistence

### How it works with k8s

On a local machine, nuketown uses btrfs snapshot rollback to wipe agent
homes on boot, with impermanence bind-mounts for persist dirs. In k8s:

- **The pod is ephemeral.** Every restart is a fresh environment —
  same philosophy as btrfs rollback, no custom initrd needed.
- **Persist dirs mount as PVCs.** The cluster's storage class handles
  replication and reattachment. No rclone scripts.
- **Build artifacts write to emptyDir.** Ephemeral pod storage, freed
  on restart — same as tmpfs but backed by node disk.

```
Pod starts
 → nix-snapshotter image provides the environment (packages, config)
 → PVCs mount at persist paths (projects, .config/claude, etc.)
 → agent starts working
 → on pod termination: PVCs persist, everything else is gone
 → on restart: same PVCs reattach, fresh environment
```

### What this replaces

| Concern | Local (current) | Cloud (k8s) |
|---------|----------------|-------------|
| Ephemeral home | btrfs snapshot rollback in initrd | Pod restart = fresh container |
| Persistence | bind-mounts from /persist (impermanence) | PVCs mounted at persist paths |
| Boot time | Snapshot restore + home-manager activate | Image pull (cached) + PVC mount |
| State drift | Possible between reboots | Impossible — every restart is fresh |
| Rollback | Reboot | Redeploy previous image tag |

### Implementation

The nuketown plugin generates PVC manifests from the agent's `persist`
list:

```yaml
# Generated from: persist = [ "projects" ".config/claude" ];
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ada-projects
spec:
  accessModes: [ ReadWriteOnce ]
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ada-config-claude
spec:
  accessModes: [ ReadWriteOnce ]
  resources:
    requests:
      storage: 1Gi
```

Mounted into the pod at the appropriate paths under the agent's home.

## ArgoCD Integration

ArgoCD replaces the entire custom reconciliation service from the
original spec. The only nuketown-specific code is a **config management
plugin** that translates nix → k8s YAML.

### How ArgoCD works here

1. **Watch** — ArgoCD polls or receives webhook from GitHub on push
2. **Evaluate** — ArgoCD runs the nuketown plugin, which calls
   `nix eval` to discover agents with `cloud.enable = true`
3. **Generate** — Plugin emits k8s manifests (Deployments, PVCs,
   ServiceAccounts, ResourceQuotas)
4. **Diff** — ArgoCD compares generated manifests against cluster state
5. **Sync** — ArgoCD applies the diff (create, update, delete resources)
6. **Report** — ArgoCD dashboard shows sync status, deploy history, logs

### The plugin

An ArgoCD config management plugin. Input: git repo path. Output: YAML.

```bash
# Pseudocode for the plugin
#!/usr/bin/env bash
# ArgoCD calls this with the repo checked out in $PWD

# Evaluate flake, find cloud-enabled agents
agents=$(nix eval --json '.#nuketown-cloud-manifests' 2>/dev/null)

# Output k8s manifests to stdout (ArgoCD consumes this)
echo "$agents" | nix-to-kube-yaml
```

Or more likely, a nix function:

```nix
# In the nuketown flake
nuketown.lib.toKubeManifests = flake: {
  # For each agent with cloud.enable = true, generate:
  #   - Deployment (nix-snapshotter image, resource requests)
  #   - PVCs (from persist list)
  #   - ServiceAccount (workload identity binding)
  #   - ResourceQuota (cost controls)
  #   - NetworkPolicy (egress-only by default)
};
```

### What ArgoCD gives us for free

Every one of these was a line item in the original spec's reconciliation
service. Now they're all off-the-shelf:

- Git webhook / polling
- State diffing (desired vs actual)
- Convergence (create, update, delete)
- Rollback (to any previous git commit)
- Web dashboard with deploy history
- RBAC and multi-tenancy
- SSO integration
- Notifications (Slack, webhook, email)
- Preview environments for PRs
- Health checks and degraded status

## Identity: Workload Identity over Key Files

### The problem with key files

On a local machine, nuketown uses sops-nix for secrets — the machine has a
host key, secrets decrypt at activation time, done. In the cloud, key-based
service account credentials are painful:

1. Generate a JSON key file
2. Encrypt it into sops or inject it at provisioning time
3. Bootstrap it before the agent can do anything
4. Rotate it periodically
5. Pray it doesn't leak

We experienced this firsthand: creating a GCP service account, downloading
a key, chowning it to the agent, activating it — a multi-step manual process
with a plaintext credential on disk.

### Workload identity: the pod *is* the credential

K8s workload identity maps a Kubernetes ServiceAccount to a cloud IAM
identity. The pod inherits its cloud credentials from the platform.
No key files. No bootstrap. No rotation.

- **GKE Workload Identity**: Pod's k8s ServiceAccount maps to a GCP
  service account. Credentials via metadata server.
- **EKS IRSA / Pod Identity**: Pod's k8s ServiceAccount maps to an
  AWS IAM role. Credentials via STS.
- **AKS Workload Identity**: Same pattern, Azure AD.

For nuketown agents this means:

```
Local identity:   Unix user + SSH key + GPG key + git config
Cloud identity:   Unix user + SSH key + GPG key + git config + workload identity
```

The workload identity extends the agent's reach to cloud APIs (storage,
compute, KMS) without adding a secret to manage.

### How it fits

```nix
nuketown.agents.ada = {
  # ... existing config ...

  cloud.identity = {
    # The plugin generates a k8s ServiceAccount bound to this.
    # No key file. The pod boots and it's already authenticated.
    gcpServiceAccount = "ada-agent@myproject.iam.gserviceaccount.com";

    # Scoping via IAM, documented as intent in nix.
    scope = "ada-*";
  };
};
```

The plugin generates:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ada
  annotations:
    iam.gke.io/gcp-service-account: ada-agent@myproject.iam.gserviceaccount.com
```

K8s + cloud IAM does the rest. The pod boots with credentials already
projected — no activation step.

### Identity chain

```
Agent identity (nuketown)
  └── Unix user (uid, home, git, GPG)
  └── K8s ServiceAccount
        └── Cloud workload identity
              └── IAM roles scoped to agent prefix
                    ├── storage: ada-* buckets/objects only
                    ├── kms: decrypt agent secrets only
                    └── no IAM admin (can't escalate)
```

### Secrets via KMS

Workload identity also solves the secrets bootstrap problem. Instead of
pre-provisioning an age key or host key for sops-nix:

1. Agent's workload identity has KMS decrypt permission
2. sops secrets encrypted with cloud KMS key
3. Pod boots → workload identity active → sops decrypts via KMS
4. No key material ever touches disk

The VM's identity *is* the decryption authorization.

## Sudo / Approval in the Cloud

On a local machine, the approval daemon pops a zenity dialog on the human's
desktop. That doesn't work for a remote pod.

**Chat-based approval** is the natural replacement — it's where the
conversation is already happening:

1. Agent requests escalation in the chat channel
2. Human approves with a reaction or reply
3. Same approval protocol, different transport

This generalizes beyond sudo to resource scaling:

| Escalation | Local | Cloud |
|-----------|-------|-------|
| Sudo | Zenity dialog | Chat approval |
| More resources | N/A (fixed hardware) | Chat approval → pod reschedule |
| GPU access | N/A (plug in device) | Chat approval → GPU node pool |
| Network access | N/A (local network) | Chat approval → NetworkPolicy update |

The approval model is the same: human-in-the-loop for escalation,
automatic for de-escalation.

## Repository Boundaries

The cloud work splits across three repositories:

### nuketown (this repo) — declares

NixOS module options that describe *what* a cloud agent looks like.
No k8s API calls. No cluster interaction. Just options.

- `nuketown.cloud` option declarations (enable, resources, scaling)
- Workload identity option declarations (`cloud.identity.*`)
- `nuketown.lib.toKubeManifests` — pure nix function: config → YAML
- Detection of cloud vs local for persistence backend selection

### nuketown-deploy (new repo) — reconciles

The ArgoCD plugin and supporting tooling.

- ArgoCD config management plugin (calls `toKubeManifests`)
- CLI: `nuketown status` (convenience wrapper around kubectl/argocd)
- Resource scaling controller (watches for agent scale requests)
- nix-snapshotter image build integration
- Documentation for cluster setup (ArgoCD, nix-snapshotter, node pools)

Much smaller than originally spec'd — ArgoCD handles reconciliation,
nix-snapshotter handles images. The plugin is glue.

### nuketown-chat (new repo) — interfaces

Chat/Matrix bot for agent interaction.

- Chat-based approval (sudo + resource scaling)
- Agent-to-agent coordination via chat rooms
- Status commands ("where is ada running?", "show me ada's resources")
- Useful independently of cloud deployment

## MVP Scope

### Phase 1: nix-to-YAML translation

- [ ] `nuketown.cloud` module options (enable, resources, scaling, identity)
- [ ] `toKubeManifests` nix function: agent config → k8s Deployment +
      PVC + ServiceAccount + ResourceQuota
- [ ] nix-snapshotter image derivation per cloud-enabled agent
- [ ] Works with `kubectl apply` manually (no ArgoCD yet)
- [ ] Test: deploy ada to a local k3s cluster

### Phase 2: ArgoCD integration

- [ ] Config management plugin (wraps `toKubeManifests`)
- [ ] ArgoCD Application manifest for a nuketown repo
- [ ] Push-to-deploy working end-to-end
- [ ] Documentation: cluster setup, ArgoCD config, node pools

### Phase 3: Orchestration UX

- [ ] Resource scaling controller (agent requests → pod spec updates)
- [ ] Chat-based approval for scaling (via nuketown-chat)
- [ ] Idle timeout → automatic downscaling
- [ ] Node pool migration (standard → build → GPU)
- [ ] Agent self-awareness: resource monitoring, scaling requests

### Phase 4: Production hardening

- [ ] Workload identity setup automation (GKE, EKS)
- [ ] KMS-backed sops secret decryption
- [ ] Network policies (egress-only by default)
- [ ] Cost controls (ResourceQuota, LimitRange, budget alerts)
- [ ] Multi-tenant cluster support
- [ ] Spot/preemptible scheduling for idle agents

## Open Questions

1. **Image build pipeline:** nix-snapshotter builds container images from
   NixOS closures. Where does this build happen? In CI (GitHub Actions →
   push to registry)? On the cluster (build pod)? Locally (push from dev
   machine)? CI → registry is probably the right default.

2. **Secrets management:** Workload identity + KMS solves cloud API
   credentials and sops decryption. But what about the initial KMS key
   binding? The cluster operator needs to set up workload identity
   federation once per cluster. Document this clearly.

3. **Networking between agents:** If ada is on your laptop with a serial
   port and vox is in a cluster, how do they collaborate beyond git?
   Tailscale sidecar in the pod? Shared git remote is probably sufficient
   for most cases.

4. **Cost controls:** Agents that request scale-ups need guardrails.
   ResourceQuota per namespace, LimitRange per pod, budget alerts.
   The scaling controller should enforce maximums from `scaling.maxResources`.

5. **Domain/identity:** Cloud agents need real email addresses and git
   identities. The current `<name>@<hostname>.local` scheme doesn't work
   for pods with random hostnames. Probably needs a real domain
   (e.g., `ada@nuketown.cloud`).

6. **Local k3s story:** Can you run `nuketown.cloud.enable = true` on
   the same machine as a local agent? k3s is already on signi. This
   could be a nice dev/test path: same config runs locally in k3s
   before deploying to a real cluster.

## Prior Art + Positioning

| Tool | What it does | Gap |
|------|-------------|-----|
| ArgoCD | GitOps reconciliation for k8s | No nix integration, no agent awareness |
| nix-snapshotter | NixOS closures as container images | No orchestration, no agent lifecycle |
| NixOps | Nix-native cloud provisioning | VM-based, abandoned |
| Colmena / deploy-rs | Push NixOS closures over SSH | VM-based, no orchestration |
| nixos-anywhere | Install NixOS on any machine | VM-based, one-shot |
| Comin | Pull-based GitOps for NixOS | VM-based, no provisioning |
| Terraform + k8s | IaC for cluster resources | Two languages, no nix integration |

Nuketown Cloud would be the first tool that:
- Uses NixOS configuration as the sole source of truth for agent
  environments *and* their cloud scheduling
- Translates nix declarations into k8s manifests (via nix-snapshotter)
- Treats infrastructure scaling as a conversation between agent and human
- Provides git-push-to-running-agent as a workflow

---

*The town is disposable. Now it runs anywhere there's a cluster.*
