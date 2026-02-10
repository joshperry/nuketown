# Nuketown Testing Results

**Date:** 2026-02-09
**Test VM:** test-basic
**Status:** Core functionality verified ✅

## Executive Summary

The nuketown module successfully creates AI agents as Unix users with declaratively managed environments. Core infrastructure works; some integration features need refinement.

## Test Environment

**VM Configuration:**
- NixOS 25.11
- 2GB RAM, 2 cores, 8GB disk
- SSH on port 2222 (host → guest:22)
- Minimal X11 (lightdm + xterm)

**Test Agent:**
```nix
nuketown.agents.ada = {
  enable = true;
  uid = 1100;
  role = "software";
  description = "Test software agent";
  packages = with pkgs; [ unstable.claude-code ];
  persist = [ "projects" ];
  sudo.enable = true;
  portal.enable = true;
};
```

## What Works ✅

### 1. Agent User Creation
```bash
$ id ada
uid=1100(ada) gid=1100(ada) groups=1100(ada)

$ ls -ld /agents/ada
drwx------ 7 ada ada 4096 Feb 10 02:29 /agents/ada
```

**Verified:**
- Unix user created with correct UID/GID
- Home directory at `/agents/ada`
- Proper permissions (700)
- Group membership correct

### 2. Home-Manager Integration
```bash
$ sudo -u ada ls -la ~
lrwxrwxrwx 1 ada ada 76 .bash_profile -> /nix/store/.../home-manager-files/.bash_profile
lrwxrwxrwx 1 ada ada 70 .bashrc -> /nix/store/.../home-manager-files/.bashrc
drwxr-xr-x 8 ada ada 4096 .config
drwxr-xr-x 2 ada ada 4096 projects  ← Persisted directory
```

**Verified:**
- Bash configuration via home-manager symlinks
- Profile loads correctly with `bash -l`
- Declarative `.config/` structure
- Persisted directories created

### 3. Package Installation
```bash
$ sudo -u ada bash -l -c 'which claude'
/etc/profiles/per-user/ada/bin/claude

$ sudo -u ada bash -l -c 'claude --version'
2.1.34 (Claude Code)
```

**Installed packages:**
- claude (Claude Code 2.1.34)
- git, ripgrep, fd, jq, curl, tree (base packages)
- direnv
- sudo shim (from home-manager)

**PATH correctly configured:**
```
/run/wrappers/bin
/agents/ada/.nix-profile/bin
/etc/profiles/per-user/ada/bin
/nix/var/nix/profiles/default/bin
/run/current-system/sw/bin
```

### 4. Git Configuration
```bash
$ sudo -u ada git config --global user.name
ada

$ sudo -u ada git config --global user.email
ada@nuketown.test
```

**Settings applied:**
- `user.name = "ada"`
- `user.email = "ada@nuketown.test"`
- `init.defaultBranch = "master"`
- `pull.rebase = true`
- `safe.directory = "*"`

Git configuration updated to home-manager 25.11 syntax (`settings.user.*`).

### 5. Nuketown Identity File
```bash
$ cat /agents/ada/.config/nuketown/identity.toml
name = "ada"
role = "software"
domain = "nuketown.test"

[description]
text = """
Test software agent
"""
```

**Purpose:** Agent self-knowledge for AI context. Located at `~/.config/nuketown/identity.toml`.

### 6. Claude Code Execution
```bash
$ sudo -u ada bash -l -c 'claude --help'
Usage: claude [options] [command] [prompt]
Claude Code - starts an interactive session by default...
```

**Verified:**
- Binary executes without errors
- Help text displays correctly
- No auth required for `--help`, `--version`
- Would require credentials for interactive use

## What Needs Work ⚠️

### 1. Sudo Approval System
**Status:** Not tested (requires graphical session)

**Architecture:**
1. Agent's sudo → wrapper script (`/run/current-system/sw/bin/sudo-with-approval`)
2. Wrapper → Unix socket (`/run/sudo-approval/socket`)
3. Socket → Approval daemon (user service under human's X session)
4. Daemon → Zenity dialog
5. Response → Wrapper → Command execution

**Issue:** Approval daemon must run under human's graphical session. In test VM:
- Human logged in via SSH: No X session for daemon
- Human logged in via QEMU GUI: Daemon should work (not tested yet)

**Test needed:**
```bash
# As ada, in VM with human's GUI session active
sudo whoami
# Should trigger zenity dialog on human's display
```

### 2. Portal System
**Status:** Not tested

**Definition:** Portal = tmux window with agent in top pane, human in bottom pane

Generated command: `portal-ada`
- Should use `fzf` to pick project
- Launch tmux split with agent + human
- Both in same directory

**Blocker:** Requires testing from host system with tmux.

### 3. Device Access (udev)
**Status:** Not applicable to VM test

Agent device rules configured but no hardware to test:
```nix
devices = [
  { subsystem = "tty"; attrs = { idVendor = "0483"; idProduct = "5740"; }; }
];
```

Would generate udev rule with `setfacl` for agent access. Needs real hardware for verification.

### 4. Authentication for Interactive Claude
**Status:** Expected limitation

Claude Code requires authentication on first run. Test VM agent has no credentials. Options:

**A. Mock credentials for testing:**
```nix
xdg.configFile."claude/.credentials.json".text = builtins.toJSON {
  token = "test-token";
};
```

**B. Real credentials via sops-nix:**
```nix
sops.secrets."ada/claude-token" = {
  sopsFile = ./secrets/agents.yaml;
  owner = "ada";
  path = "/agents/ada/.config/claude/.credentials.json";
};
```

**C. Accept limitation:** For automated testing, only use non-auth commands (`--help`, `--version`).

## Implementation Details

### SSH Access
Successfully added SSH to test VMs:
```nix
services.openssh = {
  enable = true;
  settings.PermitRootLogin = "no";
  settings.PasswordAuthentication = true;
};

virtualisation.vmVariant.virtualisation.forwardPorts = [
  { from = "host"; host.port = 2222; guest.port = 22; }
];
```

**Access:** `ssh -p 2222 human@localhost` (password: `test`)

### Boot Configuration
VMs require explicit boot/filesystem config:
```nix
boot.loader.grub.device = "/dev/vda";
fileSystems."/" = {
  device = "/dev/vda1";
  fsType = "ext4";
};
```

Without this: `nix flake check` fails with "root file system not specified"

### Home-Manager 25.11 Updates
Git configuration syntax changed:
```nix
# Old (deprecated)
programs.git.userName = "ada";
programs.git.userEmail = "ada@nuketown.test";
programs.git.extraConfig = { ... };

# New (25.11)
programs.git.settings = {
  user.name = "ada";
  user.email = "ada@nuketown.test";
  # ... other settings
};
```

## Testing Procedure

### Building Test VMs
```bash
# Build VM
nix build .#nixosConfigurations.test-basic.config.system.build.vm

# Run VM (creates disk image on first run)
./result/bin/run-nixos-vm

# Or with sudo to target specific display
sudo -u josh DISPLAY=:0 ./result/bin/run-nixos-vm &
```

### SSH Testing
```bash
# Install sshpass for automated testing
nix-shell -p sshpass

# Run commands in VM
sshpass -p "test" ssh -p 2222 \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o PreferredAuthentications=password \
  human@localhost "command"

# Test as agent
sshpass -p "test" ssh -p 2222 ... human@localhost \
  "sudo -u ada bash -l -c 'command'"
```

**Note:** Use `bash -l` to load full environment including PATH from home-manager.

### Avoiding X11 Automation Pitfalls
**Attempted:** xdotool to send keystrokes to QEMU window
**Result:** Keystrokes followed focus, typed into wrong windows
**Lesson:** SSH is more reliable for automated testing

## Architecture Insights

### Ephemeral vs. Persistent
```
/agents/ada/              ← Ephemeral (btrfs subvol, resets on boot)
  ├── .bash_profile       ← Symlink to nix store (rebuilt from home-manager)
  ├── .bashrc             ← Symlink to nix store
  ├── .config/            ← Ephemeral unless persisted
  └── projects/           ← Persisted via impermanence

/persist/agents/ada/      ← Persistent storage
  └── projects/           ← Survives reboots
```

**Philosophy:** Environment is declarative and reproducible. Only explicitly persisted data survives.

### Agent Identity Layers

**1. System-level (NixOS module):**
- UID/GID
- Base packages
- Hardware access
- Sudo permissions

**2. Home-Manager (User environment):**
- Shell configuration
- Git settings
- Directory structure
- Per-user packages

**3. Nuketown identity (Self-knowledge):**
- Role description
- Specialization
- Domain context
- Loaded by AI agent for context

### Sudo Approval Architecture

Three-layer security model:

**Layer 1: Sudo shim (agent's PATH)**
```bash
#!/bin/sh
exec /run/wrappers/bin/sudo sudo-with-approval "$@"
```
Home-manager creates shim that shadows real sudo.

**Layer 2: Approval wrapper (system package)**
```bash
#!/bin/sh
# Connect to /run/sudo-approval/socket
# Send: "username:command\n"
# Wait for: "APPROVED\n" or "DENIED\n"
# On approval: exec "$@"
```

**Layer 3: Approval daemon (user service)**
```bash
# Listen on Unix socket
# For each request:
#   - Show zenity dialog
#   - Return APPROVED/DENIED
```

**Security properties:**
- Agent never has password
- Human must interactively approve
- Daemon runs in human's session (access to display)
- Timeout prevents hanging

## Next Steps

### Immediate
1. **Test sudo approval:** Log into QEMU GUI as human, verify zenity dialog appears when ada runs `sudo`
2. **Test portal:** From host system with tmux, run `portal-ada` and verify layout
3. **Document approval daemon setup:** Instructions for enabling in human's home-manager config

### Short-term
4. **Mock approval for testing:** Add `--mock-approval` flag for automated tests
5. **Add more test VMs:** Multi-agent, hardware access scenarios
6. **Integration tests:** Scripted test suite that verifies all functionality

### Medium-term
7. **Project-level context:** Design flake integration for per-project agent instructions
8. **Memory persistence:** Decide on ephemeral vs. persistent for `.claude/` transcripts
9. **Direnv integration:** Agent workflow for entering project environments
10. **Agent conditioning:** Internal documentation about nuketown environment for agents

### Long-term
11. **Matrix/chat integration:** Async communication with agents
12. **Multi-machine agents:** Agent on VM, human on laptop, shared via network
13. **Agent-to-agent coordination:** Shared resources, git repos, chat rooms
14. **Hardware passthrough:** USB device forwarding to VMs for testing

## Lessons Learned

### 1. Declarative > Imperative
All configuration in nix. No manual setup steps. Agent environment is reproducible.

### 2. Unix Primitives Are Enough
No need for container orchestration. Users, groups, ACLs, and systemd are sufficient.

### 3. Separation of Concerns
- System config: WHO the agent is
- Home-manager: WHAT the agent has
- Project flake: WHERE the agent works
- CLAUDE.md: HOW the agent should behave

### 4. Test Early With VMs
Building test VMs uncovered:
- Missing boot configuration
- Home-manager API changes
- SSH better than X11 automation
- Need for mock approval

### 5. Ephemeral Forces Good Practices
- Configuration must be declarative
- Work must be committed to git
- Secrets must be managed properly
- Can't accumulate cruft

## Conclusion

**Nuketown works.** The core premise—AI agents as Unix users with declarative environments—is sound and implemented. The module successfully:

- Creates agents as real users
- Configures their environments via home-manager
- Installs packages declaratively
- Sets up git identity
- Provides self-knowledge via identity.toml

Remaining work is integration and refinement:
- Sudo approval (architecture complete, needs GUI testing)
- Portal system (generated, needs tmux testing)
- Device access (code complete, needs hardware)
- Project context (design phase)

**Status:** Ready for real-world testing with non-critical projects.

---

*This town works. Time to populate it.*
