# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

**Nuketown** is a NixOS framework for running AI agents as real Unix users on real machines. It provides a declarative module for managing agent identities, permissions, environments, and hardware access using native Unix primitives.

**Core Philosophy**: No containers. No orchestration layer. No agent mesh. Just Unix users with SSH keys, home directories, and jobs to do.

## Relationship to mynix

**mynix** (`/home/josh/dev/mynix`) is Josh's personal NixOS configuration repository where the nuketown concepts were originally prototyped and proven in production. It's a complete NixOS flake managing multiple machines, including `signi` (the desktop workstation).

**nuketown** (this repository) is the extracted, modularized version of the agent framework from mynix. The goal is to make it reusable as a standalone NixOS module that others can import.

**Current Development Environment:**
- You (Claude, running as the `ada` agent) are executing on the **mynix/signi** system
- This is a real production machine, not a VM
- The working mynix configuration is at `/home/josh/dev/mynix`
- The nuketown module you're developing is at `/home/josh/dev/nuketown`
- Changes to nuketown are tested in VMs, then ported back to mynix for production use

**Future State:**
- Eventually, mynix will import nuketown as a module instead of having its own implementation
- Other users will be able to add nuketown to their flakes and run agents on their own machines
- Test VMs will run complete nuketown configurations for development and CI

## Key Concepts

### Agents as Unix Users
Each agent is a real `isNormalUser` with:
- UID/GID in the 1100+ range
- Home directory at `/agents/<name>` (ephemeral, resets on boot)
- Declarative environment via home-manager
- Real cryptographic identities (SSH/GPG keys via sops-nix)
- Git configuration for signed commits

### Ephemeral Homes
Agent home directories live on a btrfs subvolume (`@agents`) that rolls back to a blank snapshot on every boot. Only explicitly persisted directories survive via impermanence. This provides:
- Clean slate after every reboot
- Protection against supply chain attacks or compromised tool state
- Immutable environments rebuilt from nix

### Security Model
- **Device access**: Per-agent udev rules with ACLs (no broad permissions)
- **Sudo approval**: Interactive zenity dialogs on human's desktop (no passwords)
- **Filesystem isolation**: Standard Unix permissions + targeted ACLs
- **Git collaboration**: Agents work in their own clones, push branches

## File Structure

```
nuketown/
├── README.md              # User-facing documentation
├── CLAUDE.md             # This file - developer guidance
├── module.nix            # Main NixOS module (~560 lines)
├── approval-daemon.nix   # Home-manager module for sudo approval daemon
└── example.nix           # Example configuration with two agents (ada, vox)
```

## Module Architecture

### `module.nix`

The main module provides `config.nuketown` options:

**Top-level configuration:**
- `enable`: Enable the framework
- `domain`: Domain for agent email addresses (default: `${hostname}.local`)
- `agentsDir`: Base directory for agent homes (default: `/agents`)
- `btrfsDevice`: UUID of btrfs device for ephemeral homes (optional)
- `sopsFile`: Default sops file for agent secrets (optional)
- `basePackages`: Packages available to all agents (default: git, ripgrep, fd, jq, curl, tree)
- `agents.<name>`: Agent definitions (see below)
- `projectDirs`: Directories for project fzf picker (default: `["~/dev"]`)

**Per-agent options** (`nuketown.agents.<name>`):
- `enable`: Enable this agent
- `uid`: Unix UID for the agent user
- `role`: Short role description (e.g., "software", "research")
- `description`: Agent's self-knowledge (multi-line)
- `git.{name,email,signing}`: Git configuration
- `packages`: Additional packages for this agent
- `extraHomeConfig`: Additional home-manager configuration
- `persist`: Directories to persist across reboots (via impermanence)
- `secrets.{sshKey,gpgKey,extraSecrets}`: sops-nix secret names
- `devices`: List of udev device rules (see Device Access below)
- `sudo.{enable,commands}`: Interactive sudo approval system
- `portal.{enable,command,layout}`: Tmux portal configuration

### Device Access

The `devices` option generates udev rules with ACLs. Each device rule has:
- `subsystem`: "tty", "usb", etc.
- `attrs`: Attribute matching (e.g., `{ idVendor = "0483"; idProduct = "5740"; }`)
- `action`: Udev action (default: "add|bind" for USB re-enumeration)
- `permission`: ACL permission (default: "rw")
- `group`: Group ownership (default: "plugdev")

Example (STM32 flight controller access):
```nix
devices = [
  {
    subsystem = "tty";
    attrs = { idVendor = "0483"; idProduct = "5740"; };
  }
  {
    subsystem = "usb";
    attrs = { product = "STM32  BOOTLOADER"; };
  }
];
```

The module automatically:
- Uses `ATTRS{...}` for tty subsystem (walks up USB tree)
- Uses `ATTR{...}` for usb subsystem (direct match)
- Applies `setfacl -m u:<agent>:<permission> $env{DEVNAME}` via udev RUN

### Sudo Approval System

When `sudo.enable = true` for an agent:

1. Agent's home-manager gets a sudo shim that calls `/run/wrappers/bin/sudo sudo-with-approval`
2. The wrapper connects to `/run/sudo-approval/socket` and sends approval request
3. Approval daemon (runs under human's graphical session) shows zenity dialog
4. On approval, wrapper execs the real command with sudo

The agent never has a password - all sudo access requires interactive approval.

### Portal System

When `portal.enable = true`, the module generates two commands:

1. **`portal-<name>`**: Open tmux window with agent in top pane, shell in bottom pane
   - Uses fzf to pick a project from `projectDirs`
   - Shells into agent via `sudo machinectl shell <agent>@`
   - Launches `portal.command` (default: claude-code) in agent's context
   - Split ratio configured via `portal.layout` (default: "75/25")

2. **`portal`**: Generic picker that selects agent, then project

This provides side-by-side collaboration: agent working in top pane, human in bottom pane, same directory.

### `approval-daemon.nix`

Home-manager module that runs the approval daemon as a user service:

```nix
home-manager.users.josh = {
  imports = [ ./nuketown/approval-daemon.nix ];
  nuketown.approvalDaemon.enable = true;
};
```

This must be enabled in the **human's** home-manager config (not the agent's) since it needs access to the graphical session for zenity dialogs.

## Usage Example

See `example.nix` for a complete configuration. Key points:

1. **Import the module:**
   ```nix
   imports = [ ./nuketown/module.nix ];
   ```

2. **Configure the framework:**
   ```nix
   nuketown = {
     enable = true;
     domain = "signi.local";
     btrfsDevice = "38b243a0-c875-4758-8998-cc6c6a4c451e";
     sopsFile = ./secrets/agents.yaml;
   };
   ```

3. **Define agents:**
   ```nix
   nuketown.agents.ada = {
     enable = true;
     uid = 1100;
     role = "software";
     description = ''
       Software collaborator. Thinks before acting.
       Works on embedded systems and NixOS configuration.
     '';
     packages = with pkgs; [ unstable.claude-code gcc-arm-embedded stm32flash ];
     persist = [ "projects" ".config/claude" ];
     secrets.sshKey = "ada/ssh-key";
     secrets.gpgKey = "ada/gpg-key";
     sudo.enable = true;
     portal.enable = true;
     devices = [ /* udev rules */ ];
   };
   ```

4. **Enable approval daemon in human's config:**
   ```nix
   home-manager.users.josh.nuketown.approvalDaemon.enable = true;
   ```

## Btrfs Setup

To use ephemeral agent homes:

1. Create btrfs filesystem with subvolumes:
   ```bash
   mkfs.btrfs /dev/disk/by-uuid/<UUID>
   mount /dev/disk/by-uuid/<UUID> /mnt
   btrfs subvolume create /mnt/@agents-blank
   btrfs subvolume snapshot /mnt/@agents-blank /mnt/@agents
   umount /mnt
   ```

2. Set `nuketown.btrfsDevice = "<UUID>"` in configuration

3. On every boot, initrd service rolls back `@agents` to `@agents-blank` snapshot

## Working with Nuketown Agents

### As a Human
- **Portal into agent workspace:** `portal-ada` or `portal` (with fzf picker)
- **View agent commits:** `git log --author=ada`
- **Verify signatures:** `git log --verify-signatures --author=ada`
- **Approve sudo requests:** Zenity dialog appears automatically
- **Check agent status:** `loginctl show-user ada`

### As an Agent (Claude Code)
When running as an agent user, you have:
- Your home at `/agents/<name>` (ephemeral)
- Persisted directories mounted via impermanence
- Device access as configured in your `devices` list
- Ability to request sudo (triggers approval dialog on human's desktop)
- Git identity for signed commits
- Tools from `basePackages` + your `packages`

**Non-interactive workflow for system changes:**
```bash
# 1. Make changes to nix configuration
# 2. Build the system
nixos-rebuild build --flake . --show-trace

# 3. Review changes
nvd diff /run/current-system result

# 4. Request approval to switch (triggers zenity dialog)
sudo sh -c 'nix-env -p /nix/var/nix/profiles/system --set ./result && ./result/bin/switch-to-configuration switch'

# 5. Cleanup
unlink result
```

## Design Principles

1. **Unix primitives over abstraction:** Use existing tools (users, ACLs, git, systemd) rather than inventing new ones
2. **Declarative everything:** All agent configuration in nix, no manual setup
3. **Ephemeral by default:** Only persist what's explicitly listed
4. **Security through boundaries:** Real Unix permissions + targeted ACLs, no broad capabilities
5. **Audit via git:** Commit history is the record of what agents did
6. **Interactive approval:** Humans approve privileged operations, no automatic elevation
7. **Device-specific access:** Grant access to specific vendor/product, not entire subsystems

## Implementation Notes

### Udev Rule Generation
The module distinguishes between `tty` and `usb` subsystems because:
- `tty` devices need `ATTRS{...}` to walk up the USB device tree
- `usb` devices need `ATTR{...}` for direct attribute matching
- USB devices that re-enumerate (serial→DFU) need `ACTION=="add|bind"`

See `module.nix:255-272` for the rule generation logic.

### Sudo Wrapper Architecture
Three layers:
1. **Agent's sudo shim** (home-manager package): Parses sudo flags and shadows `/run/wrappers/bin/sudo`
2. **Approval wrapper** (system package): Connects to socket, waits for approval, executes `sudo` with approved flags
3. **Approval daemon** (user service): Shows zenity dialog, returns APPROVED/DENIED

**Flag Handling Flow:**
When an agent runs `sudo -u josh ./command`:
1. Shim parses `-u josh` as flags, executes: `sudo sudo-with-approval -u josh ./command`
2. Wrapper gets approval (agent has NOPASSWD for `sudo-with-approval`)
3. After approval, wrapper (now root) executes: `sudo -u josh ./command`
4. Works because root doesn't need password for sudo

Socket communication uses socat with simple protocol: `username:command\n` → `APPROVED/DENIED\n`

### Portal Implementation
Portals use `machinectl shell` to get a proper login environment:
- Loads agent's full PAM session
- Sources home-manager profile via `bash -l`
- Ensures correct environment variables and PATH

The fzf picker searches `projectDirs` with `maxdepth 2`, filtering hidden directories.

## Development Workflow

### Testing Changes in VMs

When you're running as ada on mynix/signi and want to test nuketown changes:

1. **Build the test VM:**
   ```bash
   cd /home/josh/dev/nuketown
   nix build ".#nixosConfigurations.test-basic.config.system.build.vm"
   ```

2. **Start the VM as Josh (for GUI access):**
   ```bash
   sudo -u josh DISPLAY=:0 ./result/bin/run-nixos-vm &
   ```
   This triggers approval, then runs the VM in Josh's graphical session so zenity dialogs appear on his desktop.

3. **SSH into the VM:**
   ```bash
   nix-shell -p sshpass --run "sshpass -p test ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null human@localhost"
   ```
   The human user password is `test`. SSH is on port 2222 (forwarded from the VM).

4. **Test as the agent:**
   ```bash
   # Inside VM, become ada
   sudo -i -u ada

   # Test sudo approval - zenity dialog should appear on Josh's desktop
   sudo whoami
   ```

5. **Clean up:**
   ```bash
   # Kill VM (from mynix/signi, not from inside VM)
   sudo -u josh pkill -f qemu
   rm nixos.qcow2
   ```

### Testing on Production (mynix)

For production testing on mynix/signi:

1. **Test basic agent creation:**
   - Check user exists: `id ada`
   - Check home directory: `ls -la /agents/ada`
   - Check git config: `sudo -u ada git config --global user.name`

2. **Test udev rules:**
   - Plug in device
   - Check ACLs: `getfacl /dev/ttyACM0` (or appropriate device)
   - Verify agent has access: `sudo -u ada cat /dev/ttyACM0`

3. **Test sudo approval:**
   - As agent: `sudo whoami`
   - Verify zenity dialog appears
   - Check approval/denial works

4. **Test portal:**
   - Run `portal-ada`
   - Verify tmux layout
   - Check agent command runs in correct directory

5. **Test persistence:**
   - Create file in persisted directory
   - Reboot
   - Verify file survives

### Automated Testing (Planned)

Currently, testing sudo approval requires manual interaction with zenity dialogs. For CI/CD and automated testing, we plan to add a mock approval mechanism:

**Planned Implementation:**
- Add `mockApprovalPolicy` option to nuketown agents
- Policies: `"always-approve"`, `"always-deny"`, `"pattern-match"`
- Mock daemon would replace zenity with automated responses
- Enables headless VM testing and CI pipelines

**Example Configuration:**
```nix
nuketown.agents.ada = {
  enable = true;
  sudo.enable = true;

  # For testing/CI environments
  mockApprovalPolicy = "always-approve";
  # Or pattern-based:
  # mockApprovalPolicy = {
  #   allow = [ "whoami" "ls *" ];
  #   deny = [ "rm -rf *" ];
  # };
};
```

This would allow automated test suites to verify:
- Approval flow works correctly
- Commands execute with proper privileges
- Denial prevents execution
- Flag parsing works for all sudo variants

**Bonus:** With mock approval, VMs can run headless without needing Josh's GUI session. No more `sudo -u josh DISPLAY=:0` - just `./result/bin/run-nixos-vm` works fine since there's no zenity to display!

## Future Development

Potential enhancements (not yet implemented):
- Automated approval mocking for CI/CD (see above)
- Matrix/chat integration for async communication
- Git remote automation (automatic clone/push patterns)
- Multi-machine support (agent on different host than human)
- Agent-to-agent coordination primitives
- Declarative secret generation (not just deployment)
- Home snapshot/restore for debugging

## Related Files

**Nuketown (this repository):**
- `module.nix`: Main nuketown module (~600 lines)
- `approval-daemon.nix`: Home-manager module for sudo approval daemon
- `flake.nix`: Test VM configurations
- `example.nix`: Example configuration with two agents

**mynix (production reference):**
If using this in a real system, also reference:
- `/home/josh/dev/mynix`: Real-world implementation with agents in production
- `/home/josh/dev/mynix/CLAUDE.md`: Workflow for agents working with NixOS configs
- `/home/josh/dev/mynix/modules/security/sudo-approval.nix`: Production sudo-approval module (template for nuketown)
- `/home/josh/dev/mynix/users/ada/default.nix`: Production agent configuration (template for nuketown agents)

## Philosophy

From the README:

> Everything resets between rounds. The work survives in git. The agents rebuild from nix. The town is disposable. The output is not.

This framework treats AI agents as colleagues, not tools. They have:
- **Identity**: Real cryptographic credentials
- **Environment**: Declarative, reproducible tool sets
- **Boundaries**: Unix permissions, not policies
- **Agency**: Can request privileges, not just execute commands
- **History**: Git commits as audit trail

The goal is lightweight infrastructure that leverages Unix design rather than replacing it.
