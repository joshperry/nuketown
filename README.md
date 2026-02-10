# Nuketown

**AI agents as Unix users. Everything resets between rounds.**

---

Nuketown is a NixOS framework for running AI agents as real users on real machines. No containers. No orchestration layer. No agent mesh. Just Unix users with SSH keys, home directories, and jobs to do.

Every reboot, the town resets to a blank slate. Homes get leveled. Secrets redeploy. Environments rebuild from nix. The work survives because it was committed to git, not saved to disk. Nothing is precious except the output.

```
┌──────────────────────────────────────────────────────┐
│ signi                                                │
│                                                      │
│  josh (uid 1000)   ada (uid 1100)   vox (uid 1101)  │
│  ├── you           ├── software     ├── research     │
│  ├── i3, neovim    ├── claude-code  ├── web access   │
│  ├── ~/dev/        ├── git, nix     ├── git          │
│  └── the mayor     ├── serial port  └── matrix bot   │
│                    │   access (udev)                 │
│                    └── matrix bot                    │
│                                                      │
│  /agents/  ← btrfs, wiped every boot                │
│  /persist/ ← repos, keys, the stuff that matters     │
│  /nix/     ← immutable, shared, the town's bones    │
└──────────────────────────────────────────────────────┘
```

## How It Works

### Residents are Unix users

```nix
users.users.ada = {
  uid = 1100;
  group = "ada";
  isNormalUser = true;
  home = "/agents/ada";
  extraGroups = [];
};
```

That's an agent. Everything else — what it can do, what it can see, who it can talk to — is just configuration on top of a user account.

### Residents have identities

Each agent gets real cryptographic credentials managed through sops-nix:

```nix
sops.secrets."ada/ssh-key" = {
  sopsFile = ./secrets/agents.yaml;
  owner = "ada";
  path = "/agents/ada/.ssh/id_ed25519";
};
```

The private key deploys to the agent. The public key authorizes her on target machines:

```nix
# On any machine ada needs to reach
users.users.ada.openssh.authorizedKeys.keys = [
  (builtins.readFile ./keys/ada.pub)
];
```

GPG keys for signed commits. SSH keys for remote access. The trust graph is in your flake. Add a machine, rebuild, the agent can reach it. Remove it, rebuild, she can't.

```
$ git log --verify-signatures --author=ada
a3f1c9e (gpg: Good signature from "Ada <ada@signi.local>") Add throttle-scaled P gain
```

### Residents have environments

Home-manager declares each agent's tools and configuration:

```nix
home-manager.users.ada = {
  home.username = "ada";
  home.homeDirectory = lib.mkForce "/agents/ada";
  home.stateVersion = "25.11";

  home.packages = with pkgs; [
    git ripgrep fd jq curl tree
    unstable.claude-code
  ];

  programs.git = {
    enable = true;
    userName = "Ada";
    userEmail = "ada@signi.local";
    signing.signByDefault = true;
    extraConfig.safe.directory = "*";
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };
};
```

Different agents get different tools. A research agent doesn't need `claude-code`. A CI agent doesn't need `ripgrep`. The environment matches the role.

### Residents are online

Agents aren't shells you log into. They're systemd user services connected to a chat platform. You message them. They might already be working on something.

- **Always available.** Open a chat, start talking.
- **Persistent history.** Conversations live in the chat service, not a terminal buffer.
- **Device-independent.** Message from your laptop, your phone, SSH on the train.
- **Asynchronous.** "Look into the UART DMA issue." Close the laptop. Review the commits tomorrow.

The chat service is the face. The Unix user is the hands.

### The town resets every round

Agent homes live on a btrfs subvolume that rolls back to a blank snapshot on every boot:

```nix
fileSystems."/agents" = {
  device = "/dev/disk/by-uuid/...";
  fsType = "btrfs";
  options = [ "subvol=@agents" "noatime" ];
};

boot.initrd.systemd.services.rollback-agents = {
  description = "Rollback /agents to blank snapshot";
  wantedBy = [ "initrd.target" ];
  after = [ "cryptsetup.target" ];
  before = [ "sysroot.mount" ];
  unitConfig.DefaultDependencies = "no";
  serviceConfig.Type = "oneshot";
  script = ''
    mkdir -p /mnt
    mount -t btrfs -o subvol=/ /dev/disk/by-uuid/... /mnt
    btrfs subvolume delete /mnt/@agents
    btrfs subvolume snapshot /mnt/@agents-blank /mnt/@agents
    umount /mnt
  '';
};
```

Supply chain attack in a dependency? Compromised tool state? Reboot. Town's leveled. Home-manager rebuilds every house from nix. Secrets redeploy from sops. The agents are back online with clean environments in seconds.

Only what you explicitly persist survives:

```nix
environment.persistence."/persist" = {
  users.ada = {
    directories = [
      "projects"         # cloned repos, work in progress
      ".config/claude"   # auth tokens
    ];
  };
};
```

### Residents collaborate through git

Agents don't get ACLs on your checkout. They clone repos, work in their own copy, push branches. You pull when you want their work. The shared surface is the git remote, not the filesystem.

```
josh                        ada
  │                           │
  ├── git push origin main    │
  │                           ├── git pull origin main
  │                           ├── [works on feature]
  │                           ├── git push origin ada/feature
  │                           │
  ├── git fetch               │
  ├── git diff main..ada/feature
  ├── git merge ada/feature   │
```

Same as working with a remote colleague. Because that's what this is.

### Residents get hardware access

Per-device, per-agent, via udev ACLs:

```nix
services.udev.extraRules = ''
  # Ada can flash flight controllers
  SUBSYSTEM=="tty", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="5740",
    RUN+="${pkgs.acl}/bin/setfacl -m u:ada:rw %N"

  # DFU mode (no tty, raw USB device)
  SUBSYSTEM=="usb", ACTION=="add", ATTR{product}=="STM32  BOOTLOADER",
    RUN+="${pkgs.acl}/bin/setfacl -m u:ada:rw %N"
'';
```

Ada can flash an STM32 over serial. She can't touch your Yubikey. The access is declared in nix, enforced by the kernel, and specific to the device vendor/product. Plug it in and the ACL appears. Unplug it and there's nothing to access.

## Scaling the Town

### More residents

```nix
users.users.vox = {
  uid = 1101;
  home = "/agents/vox";
  # research agent — web access, no hardware
};

users.users.rio = {
  uid = 1102;
  home = "/agents/rio";
  # ops agent — k8s credentials, deploy access
};

users.users.elm = {
  uid = 1103;
  home = "/agents/elm";
  # writing agent — access to docs repos only
};
```

### More machines

The agent doesn't have to be local. Ada sits on your laptop because that's where the serial port is. Vox lives on a VM because she needs to churn for hours without draining your battery. Rio runs in CI.

Same pattern everywhere. Unix user, home-manager config, sops credentials, git remote. The chat service doesn't care where the client connects from.

```
┌─────────────────────┐     ┌─────────────────────┐
│ signi (laptop)      │     │ cloud-01 (VM)       │
│  josh, ada          │     │  vox, rio            │
│  └── serial ports   │     │  └── always-on       │
└────────┬────────────┘     └────────┬────────────┘
         │                           │
         └──── matrix server ────────┘
         └──── git remotes ──────────┘
```

### Coordination

Agents in the same chat room can talk to each other. Or not — you set the room topology. A shared git repo is a coordination primitive. A shared directory with group ACLs is another. There is no orchestration framework because there doesn't need to be.

`ls -la` tells you who can talk to whom. `git log` tells you who did what. The audit trail is the filesystem and the commit history.

## The Conversation

The reason the agents are on a chat service and not behind a CLI:

```
josh: The roll axis oscillates at high throttle.

ada:  Let me look.
      [reads src/pid/roll.c]

      P gain is fixed at 45. At high throttle, airflow over the
      control surfaces increases, so effective gain climbs. I'd
      scale P inversely with throttle — that's what INAV does.

      But before I write that — are you seeing this on both roll
      and pitch, or just roll? If it's asymmetric it might be a
      mechanical issue, not PID tuning.

josh: Just roll.

ada:  Could be prop wash on one side, but let's rule out software
      first. I'll add a throttle_scale_factor() and put it on a
      branch. Linear curve to start, we can tune the shape after
      you fly it.

      [writes code, commits, pushes]

      Branch ada/throttle-pid is ready for review.
```

That's not a task runner. That's a colleague. She asked a clarifying question before writing code. She considered a non-software explanation. She proposed an approach and waited for agreement.

The chat is the natural interface for this. Not a prompt. Not a command. A conversation.

## What Nuketown Is Not

**Not an application.** It's a NixOS module and a set of patterns. The pieces are all things that already exist — users, home-manager, sops-nix, impermanence, btrfs, udev, git, chat. Nuketown is the opinion about how to compose them.

**Not an orchestration framework.** No task queues. No agent-to-agent RPC. No DAGs. Coordination is chat rooms and git branches.

**Not model-specific.** Swap the LLM behind any agent. The identity, credentials, permissions, and git history don't change. The agent is the user, not the model.

**Not cloud-native.** It runs on your laptop. It also runs on a VM. It doesn't care. The unit of deployment is a NixOS machine, not a container.

**Not permanent.** That's the point.

---

*Everything resets between rounds. The work survives in git. The agents rebuild from nix. The town is disposable. The output is not.*
