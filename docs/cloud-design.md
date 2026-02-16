# Nuketown Agent Architecture

**One-liner:** Define an agent in Nix. Deploy it anywhere — your
workstation, your servers, the cloud.

Nuketown agents run as real Unix users on real machines. This document
describes the three deployment models, the shared infrastructure that
connects them, and the cloud deployment architecture.

---

## Deployment Models

Nuketown agents fall into three categories based on where they run and
what they do. All share the same framework — the difference is which
subsystems activate.

### Workstation Agent

**Identity is the collaborator.** The workstation agent is the human's
daily partner. It works on code, manages the machine's configuration,
and interacts side-by-side through the portal. There's typically one
per workstation — wherever the human physically sits.

```nix
# signi (josh's desktop)
nuketown.agents.ada = {
  role = "software";
  description = ''
    Software collaborator on signi. Works with josh on embedded
    systems, NixOS configuration, and web projects.
  '';
  portal.enable = true;       # tmux side-by-side
  sudo.enable = true;         # zenity approval (human is right there)
  daemon.enable = true;       # socket + XMPP + headless
  xmpp.enable = true;         # ada@6bit.com
  devices = [ /* STM32, etc */ ];
  persist = [ "projects" ".config/claude" ];
};
```

Ada is special because she bridges both roles — software collaborator
AND machine expert. You ask her about a refactor AND about why the
udev rules aren't working. There's no separate "signi" identity because
the human is co-located. Splitting them would be like having a coworker
who sits next to you but insists you email a different department to
adjust the thermostat.

**What activates:** Everything. Portal, device ACLs, ephemeral homes
(btrfs rollback), zenity approval, daemon with interactive + headless
modes, XMPP presence.

### Device Agent

**Identity is the machine.** Each managed device gets its own agent
that knows its hardware, services, and configuration. You chat with the
device about itself. The agent IS the server, the gateway, the printer.

```nix
# liver (XMPP/mail server on Hetzner)
nuketown.agents.liver = {
  role = "server";
  description = ''
    Prosody XMPP server, dovecot mail, DNS for 6bit.com.
    Runs on Hetzner VPS. NixOS managed via mynix flake.
  '';
  daemon.enable = true;
  xmpp.enable = true;         # liver@6bit.com
  sudo = {
    enable = true;
    preApproved = [            # routine ops, no interactive approval
      "systemctl restart *"
      "journalctl *"
      "certbot renew"
    ];
  };
};

# gateway (home network router)
nuketown.agents.gateway = {
  role = "network";
  description = ''
    Home network gateway. WireGuard tunnels, nftables firewall,
    DHCP/DNS for local network.
  '';
  daemon.enable = true;
  xmpp.enable = true;         # gateway@6bit.com
};

# printer (Raspberry Pi with 3D printer)
nuketown.agents.printer = {
  role = "fabrication";
  description = ''
    Raspberry Pi running Klipper for the Ender 3.
    Manages print jobs, monitors temperatures, detects failures.
  '';
  daemon.enable = true;
  xmpp.enable = true;         # printer@6bit.com
  devices = [
    { subsystem = "tty"; attrs = { idVendor = "1a86"; }; }  # printer serial
  ];
};
```

You DM `liver@6bit.com`: "Is the Prosody TLS cert still valid?" It
runs `openssl s_client`, reports back. "Renew it." It runs certbot,
restarts Prosody, confirms.

You DM `printer@6bit.com`: "What's the print status?" It checks
Klipper's API, reports bed temp, progress percentage, estimated time.

**What activates:** Daemon (headless-only), XMPP, persistent home
(no btrfs rollback — servers need state across reboots), scoped sudo
with pre-approved commands for routine operations. No portal, no zenity
(no desktop). Approval for non-routine operations flows through XMPP.

**What doesn't:** Portal (no one sitting there), ephemeral homes
(servers need persistence), device ACLs (usually — except things like
the printer's serial port).

### Cloud Agent

**Identity is the role.** Cloud agents don't care what hardware
they're on — the infrastructure is an API call away. You talk to them
about their work, not about the VM or pod they're executing in.

```nix
nuketown.agents.ada = {
  # Same ada, but cloud-deployed for a specific task
  cloud = {
    enable = true;
    resources = "standard";
    scaling.maxResources = "large";
  };
};
```

When you chat with a cloud agent, you're talking about orchestrating
resources, not managing a specific machine. "I need a GPU for this
build" is a resource request, not a sysadmin task. The approval system
gates scaling, the infrastructure is fungible.

**What activates:** Daemon (headless), XMPP, cloud resource management,
workload identity for secrets. Pod restart = clean slate (same semantics
as btrfs rollback, different mechanism).

**What doesn't:** Portal, device ACLs, zenity, btrfs. Hardware is
abstract.

### Comparison

| | Workstation | Device | Cloud |
|---|---|---|---|
| **Identity** | collaborator | the machine | the role |
| **Example** | ada on signi | liver, gateway, printer | ada in k8s |
| **Hardware** | fixed, known, hands-on | fixed, known, remote | fungible, requested |
| **You ask about** | code AND the machine | the machine itself | the work |
| **Home** | ephemeral (btrfs) | persistent | ephemeral (pod restart) |
| **Approval** | zenity + XMPP | XMPP + pre-approved | XMPP |
| **Portal** | yes | no | no |
| **Scaling** | N/A | N/A | resource tiers |
| **Count** | 1-2 (where you sit) | 1 per device | many, role-based |

### What They Share

All three models use the same `nuketown.agents` options. The daemon,
XMPP, identity (keys, git config, TOML), and approval stanzas are
shared infrastructure. The deployment model is determined by which
options you enable, not by a separate module.

Your XMPP roster becomes your infrastructure dashboard — collaborators,
servers, devices, cloud workers. You just chat with them.

```
Contacts:
  ada@6bit.com        ● Working: nuketown refactor
  liver@6bit.com      ● Ready
  gateway@6bit.com    ● Ready
  printer@6bit.com    ○ Offline
```

---

## Cloud Deployment

**One-liner:** Define a cloud agent in Nix. Push to main. It's running.

This section describes the architecture for running nuketown agents in
the cloud — Kubernetes pods with the same identity, auditability, and
approval guarantees as local agents.

Three work streams converge:

1. **XMPP** — communication and approval transport (shared with device agents)
2. **Agent daemon** — bootstrap + headless sessions (shared with device agents)
3. **K8s pods** — scheduling, scaling, persistence (cloud-specific)

### The Vercel analogy

| Vercel | Nuketown Cloud |
|--------|---------------|
| Connect GitHub repo | ArgoCD watches repo |
| Framework detection -> build | Nix evaluation -> OCI image |
| Provisions infra automatically | K8s schedules pod from manifests |
| Push to branch -> deploy | Push to branch -> ArgoCD sync |
| Preview deploys on PRs | ArgoCD preview environments |
| Dashboard for status | ArgoCD dashboard for agent status + logs |

### Why Kubernetes, Not VMs

Kubernetes replaces VM lifecycle management with one API:

- **No provider abstraction needed.** K8s API is the same everywhere —
  GKE, EKS, AKS, k3s on a VPS, k3s on your laptop.
- **No VM lifecycle management.** Pods schedule, restart, and migrate
  without custom code.
- **No custom reconciler.** ArgoCD already watches repos, diffs state,
  and converges. We just write a plugin that translates nix -> YAML.
- **Orchestration features for free.** Vertical scaling, node affinity,
  preemptible capacity, health checks, rolling updates — things we'd
  never build for raw VMs.

---

## XMPP Integration

*Shared infrastructure — serves workstation, device, and cloud agents.*

### Existing Infrastructure

Prosody runs on liver.6bit.com with dovecot dict auth. Agent email
credentials double as XMPP credentials — no separate account
provisioning needed.

- **JID**: `ada@6bit.com` (same as email)
- **Password**: `ada/email-password` in sops (shared with IMAP/SMTP)
- **Server**: liver.6bit.com
- **Auth**: dovecot dict (password verified against dovecot's user DB)

### What Nuketown Provides

Nuketown does not manage the Prosody server — that lives in mynix on
liver. Nuketown provides the client side:

**Per-agent options:**
```nix
nuketown.agents.<name>.xmpp = {
  enable = true;
  jid = "<name>@6bit.com";  # default: <name>@<domain>
  # password comes from secrets.extraSecrets or email-password
};
```

**Generated config:** When `xmpp.enable = true`, the agent's
home-manager profile includes slixmpp and the daemon connects to the
XMPP server on startup. The agent prompt gains an XMPP section
documenting the JID and available rooms.

### Approval Over XMPP

### Auth Broker as XMPP Client

The approval broker runs its own XMPP client session on the **human's**
side, connecting as `josh@6bit.com/nuketown-broker`. This is a separate
session from the human's chat client — the broker is a dedicated
approval surface, not a chat window.

```
agent runs `sudo <cmd>`
  -> sudo shim (unchanged)
    -> broker socket (unchanged)
      -> broker sends custom XMPP stanza to human's bare JID
      -> broker shows zenity popup (if local desktop available)
      <- first response wins (XMPP reply or zenity click)
        -> broker writes APPROVED/DENIED to socket
```

The Unix socket between agent and broker stays — it's the security
boundary. The broker's XMPP client and zenity are two parallel
notification channels to the human. First response wins.

### Custom Stanza Namespace

Approval requests use a custom XML namespace, not plain chat messages:

```xml
<message to="josh@6bit.com" id="a1b2c3" type="normal">
  <approval xmlns="urn:nuketown:approval" id="a1b2c3">
    <agent>ada</agent>
    <kind>sudo</kind>
    <command>nixos-rebuild switch</command>
    <timeout>120</timeout>
  </approval>
</message>
```

Different request kinds use the same namespace with different `<kind>`
values:

| Kind | Payload | Example |
|------|---------|---------|
| `sudo` | `<command>` | `nixos-rebuild switch` |
| `delegate` | `<task>`, `<agents>` | Spawn 3 researchers for API review |
| `scale` | `<from>`, `<to>` | `standard` → `large` |
| `network` | `<egress>` | Allow `pypi.org:443` |

Responses use the same namespace:

```xml
<message to="ada@6bit.com" type="normal">
  <approval-response xmlns="urn:nuketown:approval" id="a1b2c3">
    <result>approved</result>
  </approval-response>
</message>
```

This keeps the protocol structured and extensible without inventing
a new transport.

### Server-Side Filtering

Prosody routes stanzas based on namespace, so the auth broker and
chat client never interfere:

```
agent sends <message> to josh@6bit.com
  ├── has <approval xmlns="urn:nuketown:approval">
  │     -> route to resource advertising urn:nuketown:approval (broker)
  └── plain <message type="chat">
        -> route to chat client per normal XMPP rules
```

Implementation: a small Prosody module (deployed via mynix/liver) that
inspects incoming messages for the `urn:nuketown:approval` namespace
and routes them to the resource that advertises that feature via
service discovery (XEP-0030). The broker advertises the feature on
connect; the chat client doesn't.

This means agents don't need to know the broker's full JID — they
send to the bare JID and the server handles routing. If the broker
is offline, the message falls through to normal delivery (chat client
gets it as a fallback notification).

### Zenity Styling Per Agent

When the broker is running on a local desktop, zenity popups are
styled per agent — different agents get distinct visual treatment
so the human can tell at a glance who's asking:

```
┌─ ada (software) ─────────────────────┐
│  sudo: nixos-rebuild switch          │
│                                      │
│           [Approve]  [Deny]          │
└──────────────────────────────────────┘

┌─ vox (research) ─────────────────────┐
│  delegate: spawn 2 search agents     │
│  for: "survey XMPP client libraries" │
│                                      │
│           [Approve]  [Deny]          │
└──────────────────────────────────────┘
```

### Delegation as Approval

Agent team spawning flows through the same approval surface as sudo.
An agent that wants teammates requests delegation:

```
ada: I need to parallelize this — can I spin up 3 researchers?
  -> delegation request via urn:nuketown:approval (kind=delegate)
  -> broker shows zenity / sends to chat client
  -> human approves
  -> broker responds approved
  -> agent (or daemon) spawns teammates
```

Same model everywhere: escalation needs a human, de-escalation is free.
Spawning costs money and compute — it's an escalation.

### Approval Generalizes

| Escalation | Local | Cloud |
|-----------|-------|-------|
| Sudo | Zenity + XMPP | XMPP (no desktop) |
| Delegation | Zenity + XMPP | XMPP |
| More resources | N/A (fixed hardware) | XMPP -> pod reschedule |
| GPU access | N/A (plug in device) | XMPP -> GPU node pool |
| Network access | N/A (local network) | XMPP -> NetworkPolicy update |

Timeout after 120s (configurable), auto-deny on timeout. Short hex IDs
for correlation across channels.

### Presence

Agent presence maps to XMPP show states:

| State | Show | Status |
|-------|------|--------|
| Idle | `chat` | Ready |
| Working | `dnd` | Working: <task description> |
| Blocked | `away` | Waiting for sudo approval |
| Offline | --- | Daemon not running |

The human sees all agents — collaborators, servers, devices, cloud
workers — in their regular XMPP client. The roster IS the
infrastructure dashboard:

```
ada@6bit.com          ● Working: nuketown Phase 3
liver@6bit.com        ● Ready
gateway@6bit.com      ● Ready
printer@6bit.com      ○ Offline
```

### Agent-to-Agent

Agents message each other directly via JID or through MUC rooms.
Room provisioning is a server-side concern (mynix/liver config).
Nuketown agents auto-join configured rooms on connect.

Device agents and cloud agents can coordinate — liver can tell ada
about a Prosody issue, ada can push a fix and tell liver to deploy it.

### Client Library

**slixmpp** (in nixpkgs as `python3Packages.slixmpp`). Asyncio-native,
full XEP coverage (MUC, presence, disco, MAM). Runs in the same
event loop as the agent daemon — no IPC needed.

---

## Agent Daemon

*Shared infrastructure — runs on every agent regardless of deployment model.*

The daemon is the single long-running process per agent. It combines
the XMPP client, the Claude API bootstrap loop, and session management
in one asyncio event loop.

### Architecture

```
Agent Daemon (systemd user service, Python/asyncio)
+-- XMPP client (slixmpp)
|   +-- Presence publisher
|   +-- Message handler (task requests, approval responses)
|   +-- MUC participant
+-- Bootstrap loop (Claude Haiku via Agent SDK)
|   +-- Workspace resolver (clone, checkout, setup)
|   +-- Known remotes (from nix config + existing clones)
+-- Session launcher
|   +-- Interactive: launch claude-code CLI
|   +-- Headless: run Agent SDK query, stream progress to XMPP
+-- Local socket listener (for portal integration)
```

### Bootstrap Flow

When a task request arrives (via XMPP or local socket):

1. **Cache check** — is the workspace already ready? If
   `~/projects/<name>` exists and the right branch is checked out,
   skip the Claude loop entirely. Cost: $0.00, latency: ~0s.

2. **Claude bootstrap** — Haiku 4.5 resolves preconditions:
   clone repos, checkout branches, run setup. Restricted tool set
   (Bash, Read, Glob, Grep). Typical cost: $0.01-0.03, 3-8 tool calls.

3. **Launch** — start claude-code (interactive) or Agent SDK session
   (headless). Report status via XMPP.

### Known Remotes

Minimal nix option for giving the bootstrap loop hints:

```nix
nuketown.agents.<name>.daemon.repos = {
  nuketown.url = "git@github.com:joshperry/nuketown.git";
  mynix.url = "git@github.com:joshperry/mynix.git";
};
```

These are hints, not an exhaustive list. The daemon also discovers
repos from existing clones in `~/projects/`. If it can't resolve a
repo, it asks the human via XMPP rather than escalating to a bigger
model.

### Request Model

```
XMPP: "ada, work on nuketown -- fix udev block device handling"
  -> parse task, extract "nuketown" as repo hint
  -> cache check: ~/projects/nuketown exists? yes -> skip bootstrap
  -> launch claude-code in ~/projects/nuketown with task context
  -> publish presence: dnd "Working: fix udev block device handling"
  -> on completion: send summary to human via XMPP
```

### Session Lifecycle

- **Interactive (portal/local):** daemon launches claude-code CLI in
  a tmux session named after the project basename (e.g., `nuketown`).
  The portal command uses the same naming convention — if the session
  already exists, it attaches rather than creating a new one. This
  means the daemon can start a session before the human opens a portal,
  and `portal-ada` just connects to what's already running. No
  coordination needed between daemon and portal beyond the shared
  tmux session name.
- **Headless (cloud/automated):** daemon runs Agent SDK query directly.
  Streams meaningful progress to XMPP. Enforces timeout (default 4h).
- **Queue:** one task at a time. Second request gets queued with
  notification: "ada is currently working on X, your request is queued."

### NixOS Integration

```nix
nuketown.agents.<name>.daemon = {
  enable = true;
  bootstrapModel = "claude-haiku-4-5-20251001";
  apiKeySecret = "ada/anthropic-api-key";  # sops secret
  repos = { };  # known remotes
  headlessTimeout = 14400;  # 4 hours
};
```

Generates a systemd user service under the agent account:
- `ExecStart = nuketown-daemon`
- `Restart = always`
- Sets `users.users.${name}.linger = true` so the user manager
  (and the daemon) starts at boot without requiring a login session
- Reads identity.toml, repos config, API key from sops
- Connects to XMPP on startup

---

## K8s Pod Deployment

*Cloud-specific — scheduling, persistence, and secrets for cloud agents.*

### The NixOS config is the cloud API

The NixOS configuration already declares everything about the agent's
environment. The only thing missing is a thin translation layer that
turns that declaration into something a cluster can run.

You add `cloud.enable = true` to an agent, push to a branch, and a
cluster schedules it:

```
git push origin main
  -> ArgoCD detects change
    -> runs nuketown plugin (nix eval -> k8s YAML)
    -> diffs manifests vs cluster state
    -> applies changes (create / update / delete pods)
    -> agent is live
```

### Image Strategy

OCI images via `dockerTools.buildImage` from the agent's nix closure.
Push to container registry (Artifact Registry, GHCR, etc.).

nix-snapshotter is not viable on managed GKE (cannot customize
containerd plugins). It remains an option for self-hosted k3s on
NixOS once the k3s patch is rebuilt. The k3s integration patch
broke against nixpkgs k3s 1.34.3 (confirmed on signi 2026-02-12).

```nix
nuketown.cloud.imageMode = "oci";  # default
nuketown.cloud.registry = "ghcr.io/joshperry/nuketown";
```

When nix-snapshotter is available (self-hosted k3s on NixOS), each
agent's environment is a cached image layer with store-level
deduplication. "Moving" an agent to a new node means pulling only
the diff — near-instant for agents sharing a nix store.

### Pod Structure

```
Pod: nuketown-<name>
+-- initContainer: identity-init
|   Fetches secrets from KMS via workload identity.
|   Writes SSH/GPG keys, identity.toml to shared volume.
|
+-- container: agent (main)
|   Runs the agent daemon (XMPP + bootstrap + session).
|   Image: nix closure of agent packages.
|   User: agent UID from nuketown config.
|
+-- (no approval sidecar -- approval goes through XMPP)
```

### Minimal Cloud Config

For the common case of "one agent in the cloud":

```nix
nuketown.cloud.enable = true;
```

One line on top of the existing nuketown agent config. The platform
picks sensible defaults for everything else.

### Resource Tiers

Tiers are defined in `nuketown.cloud.tiers` by the cluster admin.
Each tier declares the resources and scheduling constraints for that
class of workload. `toKubeManifests` uses these definitions to
generate pod resource requests/limits, node selectors, and
tolerations.

```nix
nuketown.cloud.tiers = {
  small = {
    cpu = "1";
    memory = "2Gi";
    nodeSelector = { "nuketown.io/tier" = "small"; };
  };
  standard = {
    cpu = "2";
    memory = "4Gi";
    nodeSelector = { "nuketown.io/tier" = "standard"; };
  };
  large = {
    cpu = "4";
    memory = "8Gi";
    nodeSelector = { "nuketown.io/tier" = "large"; };
  };
  gpu = {
    cpu = "4";
    memory = "16Gi";
    resources = { "nvidia.com/gpu" = "1"; };
    nodeSelector = { "nuketown.io/tier" = "gpu"; };
    tolerations = [
      { key = "nvidia.com/gpu"; operator = "Exists"; effect = "NoSchedule"; }
    ];
  };
};
```

The tier definitions are the single source of truth — they describe
both what the agent needs and where it runs. The cluster admin
matches these to their infrastructure by labeling node pools with
`nuketown.io/tier`. Agents just reference a tier name:

```nix
nuketown.agents.ada.cloud.resources = "standard";
```

If an agent requests a tier that isn't defined, nix evaluation fails.
If the tier is defined but no matching node pool exists in the
cluster, the pod stays unschedulable — k8s reports the reason.

```nix
nuketown.cloud = {
  enable = true;
  resources = "standard";  # "small", "standard", "large", "gpu"

  scaling = {
    maxResources = "large";     # agent can request up to this
    idleTimeout = 3600;         # seconds before scaling down
  };
};
```

### Scaling as Conversation

The agent participates in its own infrastructure decisions, the same
way a colleague would:

```
ada: This rotorflight build is thrashing -- I only have 2GB here.
     Mind if I move to something bigger?
josh: yes
     *pod reschedules with 8GB, build resumes from nix cache*
ada: Back. Build's done, flashing now.
```

The mechanism:
1. Agent detects resource pressure (OOM warnings, CPU throttling)
2. Agent requests scale-up via XMPP (same UX as sudo approval)
3. Human approves (or auto-policy approves for known workloads)
4. Scaling controller updates pod resource requests
5. K8s reschedules pod on a suitable node
6. Agent resumes from persisted state (PVCs reattach)

Scaling *down* doesn't need approval — agents downsize automatically
after idle timeout. Same approval asymmetry as sudo: escalation needs
a human, de-escalation is free.

### Node Migration

Agent moves between node pools based on task:

- **Idle**: spot/preemptible capacity (cheap)
- **Working**: on-demand standard nodes
- **Building**: beefy build nodes (maybe shared with CI)
- **GPU task**: GPU node pool

The agent doesn't manage this directly. The pod spec declares resource
requests, k8s handles scheduling. But the conversation about needing
more resources is natural and human-readable.

### Self-Healing

K8s restarts crashed agents automatically. No monitoring to build.
The agent's state survives via persisted volumes. On restart:

1. Pod schedules on available node
2. PVC reattaches (persist dirs intact)
3. OCI image loads from cache
4. Agent boots into clean environment + persisted state
5. Picks up where it left off

### Persistence: persist -> PVCs

Direct mapping. Each `persist` entry becomes a PVC:

| Nuketown config | K8s resource |
|-----------------|--------------|
| `persist = ["projects"]` | PVC `nuketown-ada-projects` |
| `persist = [".config/claude"]` | PVC `nuketown-ada-config-claude` |
| Agent home (ephemeral) | `emptyDir` (pod restart = reboot) |

Pod restart gives the same clean-slate semantics as btrfs rollback.

| Concern | Local (current) | Cloud (k8s) |
|---------|----------------|-------------|
| Ephemeral home | btrfs snapshot rollback in initrd | Pod restart = fresh container |
| Persistence | bind-mounts from /persist (impermanence) | PVCs mounted at persist paths |
| Boot time | Snapshot restore + home-manager activate | Image pull (cached) + PVC mount |
| State drift | Possible between reboots | Impossible — every restart is fresh |
| Rollback | Reboot | Redeploy previous image tag |

```nix
nuketown.cloud.storageClass = null;  # cluster default
nuketown.cloud.defaultPersistSize = "10Gi";
nuketown.cloud.agents.<name>.persistSizes = {
  projects = "50Gi";  # per-directory overrides
};
```

### Secrets Bootstrap: Workload Identity

On a local machine, nuketown uses sops-nix — the machine has a host
key, secrets decrypt at activation time. In the cloud, the pod *is*
the credential:

- **GKE:** Workload Identity Federation -> Google Secret Manager
- **EKS:** IRSA -> AWS Secrets Manager
- **k3s/self-hosted:** sealed-secrets or sops with age key in k8s Secret

No key files. No bootstrap. No rotation. The workload identity extends
the agent's reach to cloud APIs without adding a secret to manage.

```
Agent identity (nuketown)
  +-- Unix user (uid, home, git, GPG)
  +-- K8s ServiceAccount
        +-- Cloud workload identity
              +-- IAM roles scoped to agent prefix
                    +-- storage: ada-* buckets/objects only
                    +-- kms: decrypt agent secrets only
                    +-- no IAM admin (can't escalate)
```

Init container authenticates via projected SA token, fetches SSH/GPG
keys and XMPP password, writes to tmpfs emptyDir shared with main
container. No key material ever touches persistent disk.

```nix
nuketown.agents.ada.cloud.identity = {
  gcpServiceAccount = "ada-agent@myproject.iam.gserviceaccount.com";
  scope = "ada-*";
};
```

### Identity Self-Provisioning

The GitHub PAT is the single root credential per agent. SSH and GPG
keys are derived from it, not pre-generated.

```
GitHub PAT (sops)
  └── agent boot
        ├── check: ~/.ssh/id_ed25519 exists?
        │     yes -> done (persisted from previous boot)
        │     no  -> generate keypair
        │            -> DELETE stale keys from GitHub (by title match)
        │            -> POST /user/keys (upload public SSH key)
        │
        ├── check: ~/.gnupg/ has signing key?
        │     yes -> done
        │     no  -> generate GPG key (from identity.toml: name, email)
        │            -> DELETE stale GPG keys from GitHub
        │            -> POST /user/gpg_keys (upload public GPG key)
        │
        └── ready (can push signed commits)
```

**One secret per agent.** The PAT in sops is the only credential the
human provisions. Everything else — SSH identity, GPG signing, GitHub
API access — derives from it.

**Persist for performance, re-derive for resilience.** Key directories
(`~/.ssh`, `~/.gnupg`) are persisted so the agent doesn't re-provision
on every reboot. But if persistence is lost (disk failure, PVC
migration, fresh cluster), the agent detects missing keys and
re-provisions from the PAT on next boot. Stale keys are cleaned up
from GitHub automatically.

**PAT scopes required:**
- `repo` — push, open PRs
- `admin:public_key` — manage SSH keys
- `admin:gpg_key` — manage GPG keys

```nix
nuketown.agents.<name>.github = {
  enable = true;
  pat = "ada/github-pat";  # sops secret name
  # SSH/GPG key dirs auto-added to persist
  # Boot service handles generation + upload
};
```

The module generates a systemd oneshot service that runs before the
daemon, checks for existing keys, and provisions if missing.

For cloud agents, the PAT itself can come from the cloud secret
store (via workload identity) instead of sops — same self-provisioning
flow, different root credential source.

### Identity Projection

`mkIdentity` and `mkIdentityToml` work unchanged — baked into the
image at build time. Runtime fields (pod name, namespace, cluster)
added by init container:

```toml
# Build-time (from mkIdentity)
name = "ada"
role = "software"
email = "ada@6bit.com"

# Runtime (patched by init container)
[cloud]
provider = "gke"
namespace = "nuketown"
pod = "nuketown-ada-7f8b9c"
```

### Networking

Egress-only by default. No ingress — agents don't serve traffic.

Required egress:
- Git remotes (github.com, port 22/443)
- AI APIs (api.anthropic.com, port 443)
- XMPP server (6bit.com, port 5222)
- Nix caches (cache.nixos.org, port 443)

### `toKubeManifests`

Pure nix function that projects agent config into k8s YAML:

```nix
nuketown.lib.toKubeManifests = config: {
  # Per agent: Namespace, ServiceAccount, Deployment,
  # PVCs, ResourceQuota, NetworkPolicy, ConfigMap (identity.toml)
};
```

Output is an attrset of `{ name = yamlString; }`. Can be applied
manually (`kubectl apply`) or via ArgoCD.

### What Doesn't Translate

| Bare metal | K8s | Notes |
|------------|-----|-------|
| `devices` | N/A | Hardware agents stay on bare metal |
| `portal` | N/A | Cloud agents interact via XMPP |
| `btrfsDevice` | `emptyDir` | Pod restart = clean slate |
| zenity approval | XMPP approval | Chat replaces desktop dialog |

---

## ArgoCD Integration

ArgoCD replaces the entire custom reconciliation layer. The only
nuketown-specific code is a config management plugin that translates
nix -> k8s YAML.

### How ArgoCD works here

1. **Watch** — ArgoCD polls or receives webhook from GitHub on push
2. **Evaluate** — ArgoCD runs the nuketown plugin, which calls
   `nix eval` to discover agents with `cloud.enable = true`
3. **Generate** — Plugin emits k8s manifests (Deployments, PVCs,
   ServiceAccounts, ResourceQuotas)
4. **Diff** — ArgoCD compares generated manifests against cluster state
5. **Sync** — ArgoCD applies the diff (create, update, delete resources)
6. **Report** — ArgoCD dashboard shows sync status, deploy history, logs

### What ArgoCD gives us for free

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

---

## Convergence

### Dependency Graph

```
XMPP client (slixmpp)
  +-- needed by: daemon (approval, presence, messaging)
        +-- needed by: k8s (pod entrypoint)
```

### Development Phases

**Phase 1 -- Local daemon (no XMPP):** DONE
Agent daemon with local socket only. Portal sends requests. Bootstrap
loop resolves preconditions. Launches claude-code. Useful immediately
on signi.

**Phase 2 -- XMPP client:** DONE
Daemon connects to 6bit.com. Presence, messaging, approval over XMPP.
Human can send tasks from phone. Approval works remotely.

**Phase 3 -- Headless sessions:** DONE
Anthropic API agent loop for fully automated sessions. Daemon streams
progress to XMPP. No portal needed. Enables device agents.

**Phase 3.5 -- Device agent deployment:**
Deploy daemon to managed NixOS machines (liver, gateway, etc.).
Pre-approved sudo commands for routine ops. XMPP identity per device.
First real test of the "chat with your infrastructure" model.

**Phase 4 -- K8s deployment:**
`nuketown.cloud` options, `toKubeManifests`, OCI image builds. Pod
runs daemon as entrypoint. Secrets via workload identity. PVCs for
persistence.

**Phase 5 -- ArgoCD:**
Config management plugin wraps `toKubeManifests`. Push nuketown nix
config -> ArgoCD syncs manifests. Full gitops.

**Phase 6 -- Orchestration UX:**
Resource scaling controller. Idle timeout auto-downscaling. Node pool
migration (standard -> build -> GPU). Chat-based scaling approval.

**Phase 7 -- Production hardening:**
Workload identity setup automation. KMS-backed sops. Network policies.
Cost controls (ResourceQuota, LimitRange, budget alerts). Multi-tenant
cluster support. Spot/preemptible scheduling for idle agents.

### Drift Insurance

The agent cannot freely sudo in cloud. All system mutations flow
through the declared nix config and the approval gate. The git repo
is the system history — every state corresponds to a commit. The
approval gate ensures all changes go through the front door.

---

## Repository Boundaries

| Repo | Role | Scope |
|------|------|-------|
| **nuketown** (this repo) | Declares | Module options, `toKubeManifests`, identity, daemon package |
| **nuketown-deploy** (new) | Reconciles | ArgoCD plugin, scaling controller, cluster docs |

nuketown-chat was originally planned as a separate repo, but the
XMPP client lives inside the daemon process and the server is managed
externally (mynix/liver). The slixmpp integration is part of the
daemon package in nuketown.

---

## Open Questions

1. **Image build pipeline.** Where does `dockerTools.buildImage` run?
   CI (GitHub Actions -> push to registry)? On the cluster (build pod)?
   Locally (push from dev machine)? CI -> registry is probably the
   right default.

2. **KMS bootstrap.** Workload identity + KMS solves secrets at runtime.
   But the cluster operator needs to set up workload identity federation
   once per cluster. Document this clearly in nuketown-deploy.

3. **Agent networking.** If ada is on your laptop with a serial port and
   vox is in a cluster, how do they collaborate beyond git? XMPP handles
   messaging. Shared git remote handles code. Probably sufficient.

4. **Cost controls.** Agents that request scale-ups need guardrails.
   ResourceQuota per namespace, LimitRange per pod, budget alerts.
   The scaling controller enforces maximums from `scaling.maxResources`.

5. **Local k3s.** Can you run `nuketown.cloud.enable = true` on the
   same machine as a local agent? k3s was on signi before the
   nix-snapshotter patch broke. This could be a nice dev/test path:
   same config runs locally in k3s before deploying to a real cluster.

---

## Prior Art

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
- Translates nix declarations into k8s manifests
- Treats infrastructure scaling as a conversation between agent and human
- Provides git-push-to-running-agent as a workflow

---

*The town is disposable. The agents run everywhere — your desk, your
servers, the cloud. You just chat with them.*
