{ config, pkgs, lib, modulesPath, ... }:

let
  humanName = "human";
  humanPassword = "demo";
in
{
  imports = [
    "${toString modulesPath}/profiles/qemu-guest.nix"
  ];

  system.stateVersion = "25.11";
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  networking.hostName = "nuketown-demo";

  # ── Boot / disk layout for the qcow2 image ──────────────────────────
  # MBR + grub is the most portable combo: qemu-system-x86_64 with no
  # extra firmware (no OVMF) just works.
  boot.loader.grub = {
    enable = true;
    device = "/dev/vda";
    efiSupport = false;
  };
  boot.growPartition = true;

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };

  # ── The human ──────────────────────────────────────────────────────
  users.mutableUsers = false;
  users.users.${humanName} = {
    isNormalUser = true;
    uid = 1000;
    description = "Nuketown demo human";
    extraGroups = [ "wheel" "video" "audio" "networkmanager" ];
    password = humanPassword;
  };
  security.sudo.wheelNeedsPassword = false;

  # ── Graphical session, auto-login ──────────────────────────────────
  services.xserver = {
    enable = true;
    desktopManager.xfce = {
      enable = true;
      # Demo VM: no need to lock the screen on idle.
      enableScreensaver = false;
    };
    displayManager.lightdm.enable = true;
  };
  services.displayManager.autoLogin = {
    enable = true;
    user = humanName;
  };

  # XFCE needs dbus + gvfs to feel right
  services.dbus.enable = true;
  services.gvfs.enable = true;

  # ── SSH fallback (handy if X breaks on host) ───────────────────────
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true;
    settings.PermitRootLogin = "no";
  };

  networking.firewall.enable = false;
  networking.useDHCP = lib.mkDefault true;

  # ── Base packages for the demo ─────────────────────────────────────
  environment.systemPackages = with pkgs; [
    xfce.xfce4-terminal
    firefox
    vim
    git
    tmux
    htop
    zenity            # used by the approval daemon
  ];

  # ── Nuketown: single agent, ada ────────────────────────────────────
  nuketown = {
    enable = true;
    domain = "nuketown.demo";
    humanUser = humanName;

    agents.ada = {
      enable = true;
      uid = 1100;
      role = "software";
      description = ''
        Demo software agent. Lives at /agents/ada. Has sudo via the
        approval daemon running in ${humanName}'s graphical session.
      '';

      packages = with pkgs; [
        unstable.claude-code
      ];

      persist = [ "projects" ];
      sudo.enable = true;
      portal.enable = true;  # default command = claude-code
    };
  };

  # portal-ada uses `tmux new-window`, which requires an existing tmux
  # session. Auto-attach interactive terminals to a shared session named
  # "portal" so `portal-ada` just works from a fresh xfce4-terminal.
  # SSH sessions are left alone so remote shells aren't hijacked.
  programs.bash.interactiveShellInit = ''
    if [ -z "$TMUX" ] && [ -z "$SSH_CONNECTION" ] && [ -t 1 ] && [ "$TERM" != "dumb" ]; then
      exec ${pkgs.tmux}/bin/tmux new-session -A -s portal
    fi
  '';

  # portal-ada's fzf picker searches ~/dev. Seed a placeholder project
  # so the picker has something to show on first run.
  systemd.tmpfiles.rules = [
    "d /home/${humanName}/dev 0755 ${humanName} users -"
    "d /home/${humanName}/dev/welcome 0755 ${humanName} users -"
  ];

  # ── Human's home-manager: approval daemon + welcome ────────────────
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.users.${humanName} = { pkgs, ... }: {
    imports = [ ../approval-daemon.nix ];

    home.stateVersion = "25.11";

    nuketown.approvalDaemon.enable = true;

    home.file."Desktop/README.txt".text = ''
      Welcome to the Nuketown demo.

      You are logged in as "${humanName}" (password: ${humanPassword}).
      Open Terminal Emulator from the XFCE menu — it lands you in a
      tmux session named "portal". Try:

        portal-ada
            Picks a project via fzf (~/dev/welcome is pre-seeded).
            Opens a tmux split: your shell on the left, agent "ada"
            running claude-code on the right, both cd'd into the
            project's directory in ada's home (/agents/ada/projects/).

        sudo machinectl shell ada@
            Drop directly into ada's machinectl session.

        From ada's shell, try:
            sudo whoami
            A zenity dialog pops up on YOUR desktop asking to approve
            the sudo request. Approve → ada gets root. Deny → ada gets
            nothing. The agent NEVER has a password.

        git config --global user.email
            Returns ada@nuketown.demo — she has her own git identity.
            Commits she makes are signed by her, not by you.

      Notes:
        - claude-code is launched with --dangerously-skip-permissions so
          ada can edit files freely inside her own home. You'll see a
          login screen the first time; you can press Ctrl-C out of it
          and explore the shell instead if you don't have an Anthropic
          account handy.
        - The agent's home (/agents/ada) is wiped on every reboot in
          the real nuketown setup. In this demo image there's no btrfs
          rollback configured, so /agents/ada persists across reboots
          — but the persist={"projects"} attribute on the agent shows
          the layout the real system uses.
    '';
  };

  # ── The qcow2 build output ─────────────────────────────────────────
  system.build.qcow = import "${toString modulesPath}/../lib/make-disk-image.nix" {
    inherit pkgs lib config;
    diskSize = "auto";
    additionalSpace = "4096M";
    format = "qcow2";
    partitionTableType = "legacy";
  };
}
