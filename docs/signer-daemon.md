# Nuketown Signer Daemon

**One-liner:** A software vault that holds operational keys outside the
workload, mediates every crypto operation through standard agent
protocols, and gives you policy, approval, audit, and live revocation
as first-class properties.

This document specifies the signer daemon: a piece of nuketown
infrastructure that holds agents' SSH, GPG, and TLS keys, exposes them
to workloads via the protocols those workloads already speak
(ssh-agent, gpg-agent, PKCS#11), and enforces approval and policy on
every operation. The same daemon — with a different transport —
becomes the cloud crypto plane for Seed microvms, replacing swtpm
injection.

---

## Motivation

### What's broken today

**For nuketown agents on signi:** agent SSH and GPG keys are
sops-encrypted at rest but get decrypted to plaintext in the agent's
ephemeral home on every session. The window where the long-term
identity exists as a plaintext file is "every minute the agent is
running." Coredumps, process snooping by other ada-owned processes,
disk inspection during sleep — all extract the key.

**For Seed microvms:** swtpm injection gives microvms a crypto
identity, but TPM 2.0 lacks ed25519, has no audit log, has no
per-operation policy, and the wrapper-encryption pattern still
materializes secrets inside the VM (which Seed acknowledges as a known
limitation). Seed doesn't use PCRs or measured boot — image integrity
is provided by nix-snapshotter — so the TPM is filling only half its
role.

**For both:** there is no way to ask "what did this identity sign on
Tuesday?", no way to revoke access without rotating the key, no way to
require approval on a per-operation basis, and no way to write
policies like "auto-approve git pulls, prompt on pushes to main."
These capabilities are structurally absent from TPMs and sops, not
just unimplemented.

### What the signer gives you

- **Operational keys never enter the workload.** Workloads hold
  socket handles, not key material.
- **Native protocols.** Workloads use ssh-agent, gpg-agent, PKCS#11 —
  the interfaces they already support. No SDK, no API integration.
- **No bootstrap secret.** Identity is bound to the transport
  (filesystem path for nuketown, vsock channel for Seed). No tokens,
  no client certs to chase.
- **Per-operation policy.** Auto-approve, prompt, deny, log, rate-limit
  — composable rules evaluated on each request.
- **Tamper-evident audit.** Every operation produces a structured,
  signed log entry. Answers "when did this key sign what, and was it
  approved?" exactly.
- **Live revocation.** Pause access at the daemon to disarm a
  compromised workload without rotating any key material.
- **Algorithm freedom.** ed25519, curve25519, RSA, NIST curves —
  whatever the chosen crypto library supports.

---

## Architecture

```
+----------------------------- josh's session ------------------------------+
|                                                                           |
|   +-----------------+   internal RPC     +-----------------+              |
|   |  signer daemon  | <----------------- |  zenity prompt  |              |
|   |  (holds keys)   |     unix socket    | (approval UX)   |              |
|   +--------+--------+                    +-----------------+              |
|            ^                                                              |
|            | internal RPC (framed JSON over unix socket)                  |
|            |                                                              |
+------------|--------------------------------------------------------------+
             |
             | bind-mounted into agent's home
             v
+-------------------------- agent's session (ada) --------------------------+
|                                                                           |
|   +-----------------+   ssh-agent proto    +------------+                 |
|   |  ssh-agent      | <------------------- |   ssh /    |                 |
|   |  shim           |   SSH_AUTH_SOCK      |   git      |                 |
|   +-----------------+                      +------------+                 |
|                                                                           |
|   +-----------------+   Assuan proto       +------------+                 |
|   |  gpg-agent      | <------------------- |  gpg /     |                 |
|   |  shim           |  S.gpg-agent.extra   |  git tag   |                 |
|   +-----------------+                      +------------+                 |
|                                                                           |
+---------------------------------------------------------------------------+
```

For Seed, the same daemon and shims, but the bind-mount becomes a vsock
channel and the zenity approval transport becomes a policy engine plus
matrix-based async approval.

### Components

**Signer daemon.** A single long-running process (per-host for
nuketown, per-VM for Seed) that:
- Holds key material in memory after unwrapping it from sealed
  storage at startup.
- Speaks an internal RPC protocol over a Unix socket.
- Enforces policy on every request.
- Emits structured audit events.
- Talks to one or more approval transports (zenity, matrix, policy).

**Protocol shims.** Small, narrow translators that present a standard
agent protocol to the workload and translate to internal RPC:
- `nuketown-ssh-agent-shim` — implements the ssh-agent protocol,
  exposes `SSH_AUTH_SOCK`.
- `nuketown-gpg-agent-shim` — implements gpg-agent's Assuan extra-socket
  protocol (signing/decryption only, no key management).
- `nuketown-pkcs11-shim` — a PKCS#11 provider for TLS workloads
  (nginx, openssl, dovecot, prosody with SASL EXTERNAL).

The shim/daemon split matters: shims have narrow surface (just parse and
translate one protocol); the daemon never speaks untrusted protocols
directly. A bug in the ssh-agent shim doesn't compromise the daemon.

**Transports.** How the shim reaches the daemon:
- **direct (nuketown):** Unix socket bind-mounted from josh's session
  into the agent's home (under `/run/nuketown-signer/socket`).
- **vsock (Seed):** AF_VSOCK channel, host-side daemon, guest-side
  shim. Mirrors swtpm's pattern.
- **mTLS (future, multi-machine):** for the case where the signer is
  not co-located with the workload.

**Approval transports.** How a "this operation needs approval" event
reaches a human:
- **zenity** — desktop dialog (nuketown on signi).
- **matrix** — XMPP/matrix message with approve/deny buttons (Seed,
  remote agents, async cases).
- **policy** — auto-approve based on rules (TLS handshakes, repetitive
  ops).

---

## Identity model

The signer holds **named identities**. An identity has:

- A name (e.g., `ada-ssh`, `ada-gpg-sign`, `liver-https`).
- An owner (the agent or service authorized to use it).
- A key type (ed25519, RSA-3072, NIST P-256, ...).
- A set of allowed operations (sign, decrypt, derive).
- A set of bound protocols (ssh-agent, gpg-agent, PKCS#11, internal).

Identities are **persistent**. They are generated once inside the
daemon (via `nuketown-signer init <name>`), stored encrypted at rest,
and never leave the daemon as plaintext. There is no "export key"
operation — by design.

This is what supersedes sops-managed agent keys: operational
identities (`ada/ssh-key`, `ada/gpg-key`) become signer-resident named
identities, declared in nix but generated inside the daemon. They
never appear in the sops file.

```nix
nuketown.agents.ada = {
  # ... existing config ...
  signer = {
    enable = true;
    identities = {
      ssh = {
        type = "ed25519";
        protocols = [ "ssh-agent" ];
      };
      gpg = {
        type = "ed25519";
        protocols = [ "gpg-agent" ];
        gpgSubkeys = [ "sign" "auth" ];   # for git signing + ssh-via-gpg
      };
    };
  };
};
```

The module materializes this by declaring the identity in the daemon's
state directory (via `systemd.tmpfiles` and `nuketown-signer init`),
wiring up the shim systemd units in the agent's home-manager, and
setting environment variables (`SSH_AUTH_SOCK`, `GNUPGHOME`).

### What sops still holds

sops continues to hold **value secrets** that workloads consume
verbatim: API tokens, database passwords, email passwords (where the
service doesn't support SASL EXTERNAL yet), service credentials.

The signer holds **operational identities**: signing keys,
authentication keys, TLS server keys, anything where the workload
performs crypto operations rather than transmitting a literal value.

---

## Wire protocols

### ssh-agent

Standard ssh-agent protocol (`SSH_AGENT_REQUEST_IDENTITIES`,
`SSH_AGENT_SIGN_REQUEST`, etc.). The shim implements the read-only
subset — no `SSH_AGENT_ADD_IDENTITY`, no `SSH_AGENT_REMOVE_IDENTITY`.
Keys are declared in nix and provisioned at daemon init time.

Approval scope: per-`SIGN_REQUEST`. The shim passes the data being
signed (or a hash thereof) to the daemon, daemon evaluates policy
(auto-approve `git fetch`-shaped requests, prompt for ambiguous ones),
returns signature.

### gpg-agent extra-socket

gpg-agent's `--extra-socket` exposes a restricted Assuan socket that
permits `PKSIGN`, `PKDECRYPT`, and a few other ops but explicitly
forbids key export. The shim implements this protocol.

For git commit signing: the workload's gpg-agent socket points to the
shim. `git commit -S` calls `gpg --detach-sign`, which talks to the
shim, which talks to the daemon. Daemon prompts (or auto-approves
based on policy: e.g., "auto-approve commit signatures matching `*.nix`
file changes").

For sops decryption: same path, daemon unwraps the DEK, returns it,
sops decrypts values locally. (See "sops integration" below for tighter
options.)

### PKCS#11

For TLS workloads — nginx with PKCS#11 keys, dovecot/postfix/prosody
doing SASL EXTERNAL with client certificates, openssl-based tools. The
shim is a `.so` library implementing the PKCS#11 v2.40 API surface
needed for TLS handshakes (`C_Sign`, `C_Decrypt`, `C_GetAttributeValue`,
session management).

This is the protocol that lets you migrate HTTPS, IMAP-over-TLS,
SMTP-over-TLS, and XMPP-over-TLS to use signer-resident keys without
touching the application code.

### Internal RPC (between shims and daemon)

Framed-JSON over Unix socket (or vsock). Operations:

```
op:  sign | decrypt | derive | list-identities | describe-identity
auth-context: { caller-uid, caller-cmdline, transport }
identity: <name>
parameters: <op-specific>
```

Response: `{ result, audit-id }` or `{ error, audit-id }`.

The protocol is intentionally simple. No streaming, no batching,
no key-exchange ceremonies — each operation is a single round-trip.

---

## Approval and policy

Every operation goes through a policy decision. The decision is one
of:

- `approve` — execute the operation, log it.
- `deny` — reject the operation, log it.
- `prompt(transport)` — escalate to the named approval transport,
  wait for response, then execute or reject.

Policies are evaluated as ordered rules with the first match winning.
Rules can match on:

- Identity (`ada-gpg`).
- Operation (`sign`, `decrypt`).
- Caller context (`uid=ada`, `cmd=git*`).
- Operation payload shape (`signed-data-hash`, `commit-message-pattern`,
  `tls-sni`, `ssh-target-host`).
- Time of day, rate (operations per minute).

Example policy (sketched, not the final config syntax):

```nix
nuketown.signer.policy = [
  # TLS handshakes: auto-approve, they happen constantly.
  { match = { protocol = "pkcs11"; op = "sign"; }; action = "approve"; }

  # Git fetches: auto-approve.
  { match = { protocol = "ssh-agent"; cmd = "git*"; data-shape = "ssh-userauth"; };
    action = "approve"; }

  # Git pushes to main: prompt.
  { match = { protocol = "ssh-agent"; cmd = "git push*main"; };
    action = "prompt"; transport = "zenity"; }

  # Everything else: prompt.
  { match = { }; action = "prompt"; transport = "zenity"; }
];
```

The point of the policy layer is that *most* operations are routine
and shouldn't bother a human, but *some* operations are interesting
and should. TPMs can't make this distinction; the signer can.

---

## Audit

Every operation produces a structured audit event:

```
{
  "audit-id":      "a8f...c1",
  "timestamp":     "2026-05-23T14:32:01Z",
  "identity":      "ada-gpg",
  "operation":     "sign",
  "caller": {
    "uid":         1100,
    "cmdline":     "git commit -S",
    "transport":   "unix:/run/nuketown-signer/socket"
  },
  "payload-hash":  "sha256:...",
  "policy-rule":   "auto-approve-git",
  "decision":      "approve",
  "duration-ms":   3
}
```

Events are written to an append-only log
(`/var/lib/nuketown-signer/audit.log`) and chained: each entry
includes the hash of the previous one, and the daemon periodically
signs the head of the chain with a dedicated audit key. This gives
tamper-evidence — an attacker who gains write access to the log can't
silently rewrite history without breaking the chain.

The audit log answers questions TPMs can't:
- When did this key last sign anything?
- What did `ada` sign on Tuesday?
- Did any operation get approved by `josh` when he was supposedly
  away?
- Is the rate of signing operations consistent with normal usage?

---

## State at rest

The daemon's key material lives encrypted on disk in
`/var/lib/nuketown-signer/`. The encryption key (the "host root
key") is unwrapped at daemon startup. Three options for the host
root key, from least to most secure:

1. **Sops-deployed** — bootstraps from existing sops-nix flow. Easiest,
   but the host root key lives on disk as a sops-managed file. Fine for
   the initial nuketown rollout.
2. **TPM-sealed** — host root key is sealed to the host's hardware TPM,
   unsealed at boot. Better than sops, no plaintext key on disk.
3. **YubiKey-derived** — daemon prompts on josh's desktop at first
   start to touch the YubiKey, derives host root key, holds in memory.
   Survives daemon restarts via short-lived OS keyring entry. Strongest
   for workstation use.

For Seed, the host root key comes from KMS via workload identity
(GKE workload identity, AWS IAM role, etc.) — same pattern as
existing cloud-native secret deployment.

The state directory itself contains:
- `identities/<name>.sealed` — per-identity encrypted private key.
- `audit.log` — append-only, chained.
- `audit-head.sig` — signature over latest audit chain head.
- `policy.evaluated` — cached compiled policy (rebuilt from nix).

---

## Nix module surface

```nix
# Module-level config (in nuketown's host options).
nuketown.signer = {
  enable = true;
  stateDir = "/var/lib/nuketown-signer";
  hostRootKey = {
    source = "sops";   # or "tpm" or "yubikey"
    sopsSecret = "nuketown-signer/host-root-key";
  };
  approval = {
    defaultTransport = "zenity";
    rules = [ /* see policy section */ ];
  };
  audit = {
    enable = true;
    signingKey = "audit";   # name of an identity used to sign audit chain heads
  };
};

# Per-agent: declare identities and wire shims into the agent's env.
nuketown.agents.ada = {
  signer = {
    enable = true;
    identities = {
      ssh = { type = "ed25519"; protocols = [ "ssh-agent" ]; };
      gpg = {
        type = "ed25519";
        protocols = [ "gpg-agent" ];
        gpgSubkeys = [ "sign" "auth" ];
      };
    };
  };
};
```

What the module generates:

1. A systemd service `nuketown-signer.service` running as a dedicated
   `nuketown-signer` user (not root, not josh).
2. tmpfiles rules to create the state directory with restrictive
   perms.
3. An init oneshot service that runs `nuketown-signer init` for any
   declared identity that doesn't yet have a key on disk. Generation
   happens inside the daemon process — keys never exist outside it.
4. For each agent with `signer.enable = true`:
   - The signer's Unix socket is bind-mounted into the agent's
     namespace at `/run/nuketown-signer/socket` (read-write, but the
     daemon authenticates by caller UID).
   - home-manager user units for the shims:
     `ssh-agent-shim.service`, `gpg-agent-shim.service`.
   - Environment variables in the agent's shell:
     `SSH_AUTH_SOCK=/run/user/<uid>/nuketown-signer/ssh.sock`,
     `GNUPGHOME=/run/user/<uid>/nuketown-signer/gnupg`, etc.

---

## sops integration

Three points on the spectrum, picking whichever fits a given workload:

### Tier 1 — Zero changes (works today via gpg-agent forwarding)

sops files encrypted to a PGP recipient whose key lives in the signer.
The agent's `GNUPGHOME` points to the gpg-agent shim. `sops --decrypt`
runs as today; behind the scenes, GPG talks to the shim talks to the
daemon. The long-term PGP identity never enters the VM.

DEK still transiently lives in VM memory during decryption (sops
operates on values locally with it), but the durable wrapping key —
the thing whose loss would compromise every sops file you'll ever have
— stays in the daemon.

### Tier 2 — Native sops KMS provider

A custom sops KMS provider (`nuketown-signer://...`) sends wrapped
DEKs to the daemon over internal RPC. Daemon unwraps, returns. Cleaner
than tier 1: no GPG dependency, no Assuan plumbing, native wire
protocol. Also unlocks support for age-encrypted sops files (which
have no agent equivalent today).

Requires a small patch to upstream `sops` to register the new provider.

### Tier 3 — Signer-resident sops semantics

Daemon understands sops file structure. Workload makes a request like
`get-value sops://secrets.yaml database.password`. Daemon does the
full DEK unwrap, decrypts only the requested field, returns just that
value. All other values in the file never enter the VM.

Biggest implementation lift, biggest blast-radius reduction. Probably
worth pursuing only after tiers 1 and 2 are in production.

---

## Non-goals

- **Replacing sops for value secrets.** sops handles deployment of
  static credential values; the signer handles operational keys.
  These are complementary.
- **Replacing the system TPM.** The signer doesn't do measured boot,
  remote attestation of host integrity, or LUKS-via-TPM. The host TPM
  can still seal the signer's host root key (tier 2 above).
- **Eliminating all in-VM plaintext.** External services that require
  literal passwords (legacy PATs, basic auth) still need plaintext in
  the workload. The signer shrinks the surface, doesn't eliminate it.
- **Generic Vault replacement.** No KV store, no dynamic database
  credentials, no transit-rekey workflow. Just keys, just crypto ops.
- **PKCS#11 token emulation at the device level.** No vsmartcard, no
  virtual CCID. PKCS#11 is exposed via the shim's library form, not as
  a system smartcard device. (Workloads that need a smartcard *device*
  are out of scope — they're rare in the workloads nuketown serves.)

---

## Development phases

**Phase 1 — Daemon skeleton + ssh-agent shim.**
- Daemon process, Unix socket, in-memory key store loaded from sops at
  startup.
- ssh-agent shim, agent-protocol sign/list operations.
- zenity approval on every operation (no policy yet, prove the loop).
- Audit log (append-only, not yet signed).
- Migration: ada's SSH key moves from sops-on-disk to
  daemon-resident.

Success criterion: `ssh josh@somewhere`, zenity prompt, approve, login
works. Ada's `~/.ssh/id_ed25519` no longer exists on disk.

**Phase 2 — gpg-agent shim.**
- Assuan protocol implementation (sign + decrypt subset).
- Identity model with subkeys (sign, auth).
- Git commit signing through the shim.
- sops decryption tier 1 (existing GPG path).

Success criterion: `git commit -S` works, sops decryption works,
ada's GPG key no longer exists on disk.

**Phase 3 — Policy engine + audit signing.**
- Rule-based policy with the matchers described above.
- Auto-approve for routine operations.
- Audit chain signing with a dedicated identity.

Success criterion: `git fetch` operations don't prompt; `git push
origin main` does prompt; audit log is tamper-evident.

**Phase 4 — PKCS#11 shim.**
- PKCS#11 library backed by the daemon.
- Initial target: nginx with a signer-held HTTPS key for one local
  service.
- Documented: how to migrate dovecot/prosody/postfix to SASL EXTERNAL.

Success criterion: a working HTTPS server where the private key lives
only in the daemon.

**Phase 5 — vsock transport for Seed.**
- vsock listener in the daemon (or a per-VM daemon launched alongside
  cloud-hypervisor).
- VM-side shims connect via vsock and re-expose Unix sockets to the
  workload.
- Policy + matrix approval (no zenity in the cloud).

Success criterion: a Seed microvm with no swtpm, no key material
on the VM filesystem, doing TLS + SSH + git-signing via the signer.

**Phase 6 — sops integration tier 2 / 3.**
- Native KMS provider for sops, age support.
- Eventually: signer-resident "get this value" oracle.

**Phase 7 — Production hardening.**
- TPM-sealed host root key option.
- YubiKey-derived host root key option.
- Policy DSL improvements.
- Operational metrics and rate alerts.

---

## Repository boundaries

| Component | Repo | Why |
|-----------|------|-----|
| Daemon + shims | **nuketown** | The daemon is core nuketown infrastructure; identity options live next to agent options. |
| sops native provider | **upstream sops** | Lands as a contribution; usable outside nuketown. |
| Seed vsock integration | **seed** | The vsock launch wiring is Seed-specific; the daemon binary comes from nuketown as a flake output. |
| Matrix approval transport | **nuketown-chat** (or nuketown daemon) | Reuses the XMPP/matrix client; same code that handles sudo approval over chat handles signer approval. |

Sensible default: ship as a flake output of nuketown
(`nuketown.packages.x86_64-linux.signer-daemon`,
`nuketown.nixosModules.signer`). Seed and any other consumer import it.

---

## Open questions

1. **Internal RPC wire format.** Framed JSON is simplest. Cap'n Proto
   would be faster and gives a schema. gRPC is heavyweight for what's
   effectively a local IPC. Probably start with framed JSON and revisit
   if performance becomes an issue.

2. **Process model.** One daemon per host with multi-tenancy
   (multiple agents share the daemon, authenticated by UID), or one
   daemon per agent (mirrors swtpm-per-VM model). For nuketown,
   per-host is simpler; for Seed, per-VM is the natural fit. The
   daemon should work in either mode without code changes.

3. **PKCS#11 surface.** The PKCS#11 spec is enormous; we only need a
   small slice for TLS. Decide which functions to implement and which
   to error on. OpenSC's `pkcs11-spy` is useful for figuring out what
   real applications actually call.

4. **Policy DSL.** Nix-as-config is convenient for declaration but
   awkward for hot-reload and runtime evaluation. Probably compile
   nix-declared policy to a serialized format the daemon loads. The
   evaluator should be small and auditable.

5. **Approval over matrix.** What does the message look like? Inline
   approve/deny via reactions? An XHTML-IM rendered card? This belongs
   in nuketown-chat's design, but the signer needs an API for it.

6. **Backup and recovery.** If the daemon's state directory is lost,
   so are the keys. Backup strategy: encrypted snapshot to S3/local
   disk, sealed to either the host TPM or a recovery YubiKey. Manual
   restore process documented.

7. **First-use TOFU vs. declared identities.** If a workload asks for
   an identity that doesn't exist, should the daemon auto-create
   (TOFU) or error? Probably error — identities should be declarative,
   created at nix-build time.

8. **Interaction with existing ssh-agent / gpg-agent.** What happens
   if a user accidentally also runs the system ssh-agent? Document
   that `SSH_AUTH_SOCK` set by the shim should win, and provide a
   pre-flight check.

---

## Prior art

| Tool | What it does | Gap (for our use case) |
|------|--------------|------------------------|
| Hardware TPM | Sealed keys, measured boot | No ed25519 (mostly), no policy, no audit, opaque |
| YubiKey OpenPGP | Hardware GPG/SSH agent | Touch-to-sign breaks autonomous workflows, single-tenant |
| `ssh-tpm-agent` | ssh-agent backed by TPM | TPM algorithm limits; no policy/audit |
| HashiCorp Vault (transit) | Network crypto-ops service | Client auth required (bootstrap problem), SDK integration |
| AWS KMS / GCP KMS | Cloud crypto-ops service | Vendor lock-in, per-call cost, network latency |
| `gpg-agent` | Local GPG signing | No policy/audit/revocation, no remote use |
| `pkcs11-provider` | OpenSSL provider for PKCS#11 | Provider only; needs a token to talk to |
| SoftHSM | Software PKCS#11 token | Just storage; no policy, no audit, no remote |
| `vsmartcard` | Virtual smartcard via vpcd | Heavyweight; CCID/APDU complexity unnecessary for our use cases |
| sops-nix | Declarative sops deployment | Decrypts to disk; durable key lives in workload |

The nuketown signer combines the local-and-fast properties of ssh-agent
and gpg-agent with the policy, audit, and remote-mediation properties
of Vault and cloud KMS. It's not novel cryptographically; the novelty
is the integration: declared in nix, mediated by the approval daemon
you already have, transport-agnostic (Unix socket → vsock → mTLS),
and structurally aligned with how the rest of nuketown thinks about
agent identity.

---

*Keys live where humans live. Workloads ask, the daemon answers, the
log remembers, the human can always say no.*
