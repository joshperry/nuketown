# Cloud Agent Design

This document describes the architecture for running nuketown agents
remotely — outside the human's physical workstation — while preserving
the identity, auditability, and approval guarantees of the local model.

Three work streams converge to make this possible:

1. **XMPP** — communication and approval transport
2. **Agent daemon** — bootstrap orchestrator with Claude API loop
3. **K8s pods** — deployment target for cloud agents

Each is independently useful and can be developed in parallel.

---

## 1. XMPP Integration

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

The approval broker gains an XMPP backend alongside zenity:

```
agent runs `sudo <cmd>`
  -> sudo shim (unchanged)
    -> broker socket (unchanged)
      -> broker sends XMPP message to human's JID
        -> human replies "yes <id>" or "no <id>"
          -> broker writes APPROVED/DENIED to socket
```

The Unix socket between agent and broker stays — it's the security
boundary. XMPP replaces only the human-facing notification channel.

**Hybrid mode:** When both backends are available, the broker sends a
zenity popup AND an XMPP message. First response wins. This preserves
local desktop workflow while enabling remote approval.

**Message format:**
```
[Approval #a1b2c3]
Agent: ada
Command: nixos-rebuild switch
Reply "yes a1b2c3" or "no a1b2c3"
```

Short hex IDs for human-friendly typing. Timeout after 120s (configurable),
auto-deny on timeout.

### Presence

Agent presence maps to XMPP show states:

| State | Show | Status |
|-------|------|--------|
| Idle | `chat` | Ready |
| Working | `dnd` | Working: <task description> |
| Blocked | `away` | Waiting for sudo approval |
| Offline | — | Daemon not running |

The human sees agent status in their regular XMPP client.

### Agent-to-Agent

Agents message each other directly via JID or through MUC rooms.
Room provisioning is a server-side concern (mynix/liver config).
Nuketown agents auto-join configured rooms on connect.

### Client Library

**slixmpp** (in nixpkgs as `python3Packages.slixmpp`). Asyncio-native,
full XEP coverage (MUC, presence, disco, MAM). Runs in the same
event loop as the agent daemon — no IPC needed.

---

## 2. Agent Daemon

The daemon is the single long-running process per agent. It combines
the XMPP client, the Claude API bootstrap loop, and session management
in one asyncio event loop.

### Architecture

```
Agent Daemon (systemd user service, Python/asyncio)
├── XMPP client (slixmpp)
│   ├── Presence publisher
│   ├── Message handler (task requests, approval responses)
│   └── MUC participant
├── Bootstrap loop (Claude Haiku via Agent SDK)
│   ├── Workspace resolver (clone, checkout, setup)
│   └── Known remotes (from nix config + existing clones)
├── Session launcher
│   ├── Interactive: launch claude-code CLI
│   └── Headless: run Agent SDK query, stream progress to XMPP
└── Local socket listener (for portal integration)
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
XMPP: "ada, work on nuketown — fix udev block device handling"
  -> parse task, extract "nuketown" as repo hint
  -> cache check: ~/projects/nuketown exists? yes -> skip bootstrap
  -> launch claude-code in ~/projects/nuketown with task context
  -> publish presence: dnd "Working: fix udev block device handling"
  -> on completion: send summary to human via XMPP
```

### Session Lifecycle

- **Interactive (portal/local):** daemon launches claude-code CLI,
  fire-and-forget. Human watches via portal.
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
- Reads identity.toml, repos config, API key from sops
- Connects to XMPP on startup

---

## 3. K8s Pod Deployment

### Image Strategy

OCI images via `dockerTools.buildImage` from the agent's nix closure.
Push to container registry (Artifact Registry, GHCR, etc.).

nix-snapshotter is not viable on managed GKE (cannot customize
containerd plugins). It remains an option for self-hosted k3s on
NixOS once the k3s patch is rebuilt.

```nix
nuketown.cloud.imageMode = "oci";  # default
nuketown.cloud.registry = "ghcr.io/joshperry/nuketown";
```

### Pod Structure

```
Pod: nuketown-<name>
├── initContainer: identity-init
│   Fetches secrets from KMS via workload identity.
│   Writes SSH/GPG keys, identity.toml to shared volume.
│
├── container: agent (main)
│   Runs the agent daemon (XMPP + bootstrap + session).
│   Image: nix closure of agent packages.
│   User: agent UID from nuketown config.
│
└── (no approval sidecar — approval goes through XMPP)
```

### Persistence: persist -> PVCs

Direct mapping. Each `persist` entry becomes a PVC:

| `persist = ["projects"]` | PVC `nuketown-ada-projects` |
| `persist = [".config/claude"]` | PVC `nuketown-ada-config-claude` |
| Agent home (ephemeral) | `emptyDir` (pod restart = reboot) |

Pod restart gives the same clean-slate semantics as btrfs rollback.

```nix
nuketown.cloud.storageClass = null;  # cluster default
nuketown.cloud.defaultPersistSize = "10Gi";
nuketown.cloud.agents.<name>.persistSizes = {
  projects = "50Gi";  # per-directory overrides
};
```

### Secrets Bootstrap

Cloud agents can't use sops with a host age key. Instead:

- **GKE:** Workload Identity Federation -> Google Secret Manager
- **EKS:** IRSA -> AWS Secrets Manager
- **k3s/self-hosted:** sealed-secrets or sops with age key in k8s Secret

Init container authenticates via projected SA token, fetches SSH/GPG
keys and XMPP password, writes to tmpfs emptyDir shared with main
container.

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
  # PVCs, NetworkPolicy, ConfigMap (identity.toml)
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

## Convergence

### Dependency Graph

```
XMPP client (slixmpp)
  └── needed by: daemon (approval, presence, messaging)
        └── needed by: k8s (pod entrypoint)
```

### Development Phases

**Phase 1 — Local daemon (no XMPP):**
Agent daemon with local socket only. Portal sends requests. Bootstrap
loop resolves preconditions. Launches claude-code. Useful immediately
on signi.

**Phase 2 — XMPP client:**
Daemon connects to 6bit.com. Presence, messaging, approval over XMPP.
Human can send tasks from phone. Approval works remotely.

**Phase 3 — Headless sessions:**
Agent SDK for fully automated sessions. Daemon streams progress to
XMPP. No portal needed.

**Phase 4 — K8s deployment:**
`nuketown.cloud` options, `toKubeManifests`, OCI image builds. Pod
runs daemon as entrypoint. Secrets via workload identity. PVCs for
persistence.

**Phase 5 — ArgoCD:**
Config management plugin wraps `toKubeManifests`. Push nuketown nix
config -> ArgoCD syncs manifests. Full gitops.

### Drift Insurance

The agent cannot freely sudo in cloud. All system mutations flow
through the declared nix config and the approval gate. The git repo
is the system history — every state corresponds to a commit. The
approval gate ensures all changes go through the front door.

---

## New Repos

| Repo | Role |
|------|------|
| **nuketown** (this repo) | Module options, `toKubeManifests`, identity, daemon package |
| **nuketown-deploy** (new) | ArgoCD plugin, scaling controller, cluster docs |

nuketown-chat was originally planned as a separate repo, but since
the XMPP client lives inside the daemon process and the server is
managed externally (mynix/liver), there's no need for a standalone
chat repo. The slixmpp integration is part of the daemon package
in nuketown.
