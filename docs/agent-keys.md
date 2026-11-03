# Agent Key Custody and Unlock

*Ada and Joshua Perry, 2026-11-03. Replaces `signer-daemon.md` (2026-05-30),
whose per-operation design is kept below as a rejected alternative.*

**One-liner:** an agent's private keys live where it can use them but never
read them, and the one human step in using a key — unlocking it — goes
through the approval card, with lifetimes and screen-lock wipes that keep
keys locked whenever the human isn't around.

---

## The model

A careful human keeps their SSH and GPG keys in an agent (gpg-agent, or a
YubiKey behind one). Programs ask the agent for signatures; nothing gets the
key itself. The only time the human is involved is when a key is unlocked:
typing the passphrase or touching the token the first time it's used, after
which it stays usable until a cache timeout or a lock.

Nuketown does the same for agents, with two substitutions:

| A human has | A nuketown agent has |
|---|---|
| A YubiKey, a hardware boundary the key can't cross | A separate key-holder uid (`ada-keys`) the agent can't read |
| Typing a passphrase at the first use | An approval card asking to unlock that key, for a stated time |
| Pulling the YubiKey out when walking away | Keys wiped after the human's screen has been locked for a while, or on suspend |

What this design deliberately does **not** do is approve each signature.
Per-operation rules were the weakest part of the earlier design (see
[Rejected alternatives](#rejected-alternatives)). Rules about *actions* —
"don't push to main", "don't deploy" — belong where the action happens:
branch protection on the git server, sudo for privileged commands.

## What's broken today

`secrets.sshKey` and `secrets.gpgKey` are sops secrets decrypted into the
agent's home on every boot. The agent's long-term identity is a plaintext
file for as long as the agent runs, readable by any process running as the
agent, and copyable by anything that compromises it.

---

## Architecture

```
+---------------------------- signi ----------------------------------------+
|                                                                           |
|  josh's session                          nuketown-approval                |
|  +----------------+  REQUEST:<id>       +-------------------------+       |
|  | approval card  | <------------------ | nuketown-approve        |       |
|  | (broker)       | -- APPROVED -------> | kind: key-unlock        |       |
|  +----------------+  + decrypted        +------------^------------+       |
|   logind session      passphrase                     | sudo -u            |
|   LockedHint ----.                                    | nuketown-approval  |
|                  |                                    |                    |
|  ada-keys (uid)  v                                    |                    |
|  +------------------------+  pinentry   +------------+-----------+        |
|  | nuketown-keyholder     |------------>| nuketown-pinentry      |        |
|  | (locks, TTLs, oplog)   |             +------------------------+        |
|  +-----------+------------+                          ^                    |
|              | gpg-connect-agent                     | asks for a         |
|              v                                       | passphrase         |
|  +---------------------------------------------------+---+               |
|  | gpg-agent --enable-ssh-support  (stock)               |               |
|  |   /var/lib/nuketown-keys/ada/  passphrase-protected   |               |
|  |   S.gpg-agent.extra    S.gpg-agent.ssh                |               |
|  +-----------^-----------------------^-------------------+               |
|              |                       |                                    |
|  ada (uid)   | socket redirect       | SSH_AUTH_SOCK                      |
|  +-----------+------+     +----------+-------+                            |
|  | gpg, git -S      |     | ssh, git push    |                            |
|  +------------------+     +------------------+                            |
+---------------------------------------------------------------------------+
```

### The key-holder: one stock gpg-agent per agent

Each agent with `keys.enable` gets a system user `<agent>-keys` running
**stock gpg-agent** with `enable-ssh-support`. One agent, not ssh-agent plus
gpg-agent, because gpg-agent asks for a passphrase **when a key is used**
(through its pinentry), while ssh-agent can only hold keys someone already
added with `ssh-add`. Lazy, on-demand unlock is the property the whole
design rests on.

- **Keys at rest:** `/var/lib/nuketown-keys/<agent>/` (persisted, mode 0700,
  owned by `<agent>-keys`), in gpg-agent's own `private-keys-v1.d` format,
  each protected by a passphrase.
- **Passphrases at rest:** one file per key, GPG-encrypted to the human's key
  (the YubiKey), the same pattern as mynix's `sops-age-yubikey`. Nothing on
  disk decrypts without the human's token.
- **Sockets the agent reaches:**
  - `S.gpg-agent.extra`, gpg-agent's restricted socket, made for
    forwarding to untrusted machines. Signing and decryption work; key
    export and passphrase presetting don't.
  - `S.gpg-agent.ssh`, exposed to the agent as `SSH_AUTH_SOCK`.
- **Permissions:** both sockets sit in `/run/nuketown-keys/<agent>/`, mode
  0750, group `<agent>-keys-clients`, whose only member is the agent.

Because the key-holder is a different uid, the agent can't ptrace it, read
its `/proc/<pid>/mem`, or open its key files. That uid boundary plays the
role the YubiKey's hardware plays for a human.

### The agent's side

- `SSH_AUTH_SOCK=/run/nuketown-keys/<agent>/S.gpg-agent.ssh`.
- The agent's own gpg agent socket is a GnuPG socket-redirect file
  (`%Assuan%` / `socket=/run/nuketown-keys/<agent>/S.gpg-agent.extra`), and
  `no-autostart` keeps gpg from spawning a local agent. `gpg`, `git commit -S`
  and `sops` work unchanged.
- The agent's keyring holds only **public** keys, so gpg can find the
  signing key and verify signatures.
- No private key, passphrase or sops copy of either exists in the agent's
  home. `secrets.sshKey` / `secrets.gpgKey` are no longer deployed.

### Unlock: an approval kind

gpg-agent's `pinentry-program` is `nuketown-pinentry`, running as
`<agent>-keys`. When a locked key is used:

1. gpg-agent asks the pinentry for the key's passphrase. Its description
   names the key (keygrip, comment, and for SSH the fingerprint).
2. `nuketown-pinentry` maps the keygrip to the identity name declared in nix
   and requests a new approval kind, `key-unlock`:
   `sudo -u nuketown-approval nuketown-approve --kind key-unlock …`
3. The card reads *"ada wants to unlock **git-signing** for **8h**"*. The
   collector (root) writes the identity, its policy and the agent's recent
   unlock history into `kind/`. Unlocks are routine, so the collector writes
   `kind/skip-review`: no reviewer pass, no delay.
4. On Approve, the broker decrypts that key's passphrase file with the
   human's GPG key — the existing `DECRYPT:<src>:<dest>` path, so the PIN
   prompt and `touchApproves` behave as they do for `sops-unlock` today.
5. The pinentry hands the passphrase to gpg-agent, removes it, and gpg-agent
   caches the unlocked key. The signature that triggered the unlock
   completes; the agent never saw a prompt.

A denial (with its reason) fails the operation, and the reason is visible in
the agent's gpg or ssh error.

Confirm-each-use keys (below) use the same pinentry's `CONFIRM` path: an
approval card with no decrypt.

### Lock: TTLs and wipes

`nuketown-keyholder`, a small service running as `<agent>-keys`, owns every
reason a key goes back to locked:

| Trigger | Effect |
|---|---|
| A key's own TTL expires | That key's cache entry is cleared (`CLEAR_PASSPHRASE`) |
| The human's screen has been locked for `lockAfterScreenLock` (default 1h30m) | Every key is wiped |
| The human unlocks the screen before then | Timer cancelled |
| Suspend (logind `PrepareForSleep`) | Every key is wiped immediately |
| The human logs out | Every key is wiped |
| `nuketown-keys lock <agent>`, run by the human | Every key is wiped |

Screen lock is read from the human's logind session (`LockedHint`), which
signi's `xss-lock-hinted` already sets, and which any locker that reports to
logind sets on Wayland too. A full wipe is `gpgconf --reload gpg-agent`,
which flushes the cache.

gpg-agent's own `max-cache-ttl` / `max-cache-ttl-ssh` are set to the longest
TTL any key declares, as a backstop if the keyholder service dies.

### Key policy

Policy is per identity, declared in nix, and the unit of policy is the key.
That pushes toward separating keys by blast radius: a key used all day stays
unlocked all day, and a key that can do damage asks every time.

```nix
nuketown.agents.ada.keys = {
  enable = true;
  lockAfterScreenLock = "1h30m";

  identities = {
    git-signing = {
      type = "gpg";
      usage = [ "sign" ];
      ttl = "8h";
    };
    ssh = {
      type = "ssh";
      ttl = "8h";
    };
    deploy = {
      type = "ssh";
      ttl = "15m";
      confirm = true;   # approval card on every use, not just unlock
    };
  };
};
```

How the fields map onto stock gpg-agent:

| Field | SSH keys | GPG keys |
|---|---|---|
| `ttl` | Per-key TTL column in `sshcontrol` | Enforced by `nuketown-keyholder` clearing that keygrip's cache entry |
| `confirm` | `confirm` flag in `sshcontrol` | A separate gpg-agent instance with `ignore-cache-for-signing` (only if a GPG key ever needs it) |

Identities are generated inside the key-holder (`nuketown-keys init <agent>
<identity>`) or imported once from the current sops secrets during
migration. There is no export command.

---

## The oplog

Every component already writes to journald, and journald stamps each entry
with fields the sender can't forge (`_UID`, `_PID`, `_COMM`, `_SYSTEMD_UNIT`).
An entry from `ada` can't pass as one from `ada-keys` or `nuketown-approval`.
The oplog is a common field set across those sources plus a viewer that
merges them.

| Source | Trust | Records |
|---|---|---|
| `nuketown-approval` | Outside the agent | Unlocks, confirms, sudo, switches: who approved, the reason, the policy shown |
| `<agent>-keys` | Outside the agent | Each signature and decryption (identity, caller), every lock and wipe and its trigger |
| Remote side | Outside the agent | sshd logins, pushes the git server accepted, signed commits themselves |
| The agent | The agent's claim | Why: task, command, session id (Claude Code `PostToolUse` hook → `systemd-cat -t nuketown-oplog-claim`) |

Shared fields: `NUKETOWN_AGENT`, `NUKETOWN_IDENTITY`, `NUKETOWN_OP`
(`unlock`, `sign`, `decrypt`, `lock`, …), `NUKETOWN_REQUEST` (approval id,
when there is one), `NUKETOWN_SESSION` (claims only).

`nuketown-oplog [--agent ada] [--since …]` merges these into one timeline,
grouped by request id and time. Its most useful output is a **mismatch**: a
signature recorded by the key-holder with no claim from the agent near it is
exactly what to look into. The agent's claims are context, never evidence.

---

## Nuketown agents inside Seed

Seed's own design (`seed/docs/instance-keys-and-transport.md`) runs a stock
gpg-agent per instance on the host and forwards its sockets into the VM. A
nuketown agent running inside a Seed instance composes with it directly:
**the pinentry is the unlock source.** On a Seed host the instance's
key-holder normally unlocks by deployment policy; for a nuketown agent its
pinentry routes to nuketown approval (over chat, since there's no desktop)
instead. The same TTLs and lock triggers apply, with lifecycle events
(VM stop, scale-down) added to the list.

---

## Migration

1. Add `<agent>-keys`, its gpg-agent and keyholder units, sockets, and
   `nuketown-pinentry`, behind `keys.enable`.
2. Import ada's current SSH and GPG keys (from sops) into the key-holder,
   protect each with a fresh random passphrase, and encrypt each passphrase
   to josh's GPG key.
3. Point ada's `SSH_AUTH_SOCK` and gpg socket at the key-holder; check
   `ssh`, `git commit -S`, `git push`, and `sops -d`.
4. Stop deploying `ada/ssh-key` and `ada/gpg-key`; confirm nothing under
   `/agents/ada` holds private key material; remove them from the sops file.
5. Add the `key-unlock` kind, lock triggers, and oplog fields; then the
   viewer.

Success: ada signs commits and pushes over SSH after one approval card in
the morning; the keys are wiped 90 minutes into josh's lunch; nothing in
ada's home or memory holds a private key.

## Open questions

1. **Passphrase handoff.** The broker's `DECRYPT` path writes to a file the
   pinentry reads. A pipe would avoid a plaintext passphrase in `/run` even
   briefly. Check what the broker can do without a protocol change.
2. **Per-signature logging.** Check what gpg-agent's log (verbose, IPC
   debug) records per SSH sign request and per `PKSIGN`. If it isn't enough,
   a log-only proxy in front of each socket (no policy) is the fallback.
3. **SSH-socket management requests.** gpg-agent's SSH socket accepts
   `ssh-add` (add identity) and removal requests. Adding needs a passphrase,
   so it would show up as an unlock card, but check removal and decide
   whether to filter both.
4. **`CLEAR_PASSPHRASE` per keygrip.** Verify that clearing one GPG key's
   cache entry works as expected with the current gnupg, and that the
   socket-redirect file is honored on Linux.
5. **Backup.** The key-holder's state directory is the only copy of keys
   generated there. Encrypted backup to the human's key, or accept
   regenerate-and-re-enroll on loss.

---

## Rejected alternatives

**A per-operation signer daemon** (`signer-daemon.md`, May 2026). Custom
shims for ssh-agent, gpg-agent and PKCS#11 in front of a daemon that applied
policy to every operation.
- Rules matched on `/proc/<pid>/cmdline`, which the agent controls; they can
  reduce prompts but can't stop a compromised agent.
- The SSH data being signed doesn't name the target host unless the client
  uses `session-bind@openssh.com`.
- Faking gpg-agent's restricted socket means reimplementing gpg-agent.
- Routine signing would have meant a stream of prompts.
The idea of keeping keys out of the agent's reach is kept; per-operation
gating is not.

**A virtual smartcard.** gpg-agent supports card keys natively through
scdaemon, but a card only sees APDUs, not who asked or why; pcscd is
system-wide and would need per-agent isolation; the OpenPGP card and PIV
specs are large to emulate; and gpg-agent rejects data over ~476 bytes on its
way to scdaemon, which already forced a gnupg patch for the real YubiKey on
signi. A separate uid gets the same "can use, can't take" property with
stock software.

**ssh-agent for SSH keys.** It can't ask for a passphrase at first use, so
something would have to run `ssh-add` ahead of time. gpg-agent's SSH support
can.

**Approval on every use.** Kept only as the per-key `confirm` flag, for keys
whose blast radius justifies it.

---

*Keys live where the agent can use them and never read them. The human
unlocks them, the clock and the screen lock re-lock them, the log keeps the
record.*
