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
    desktopManager.xfce.enable = true;
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
        # Keep the demo image small: skip claude-code by default.
        # The portal opens a plain shell so the sudo→zenity story is
        # visible without needing API keys.
      ];

      persist = [ "projects" ];
      sudo.enable = true;
      portal = {
        enable = true;
        # Override the default (claude-code) so the demo works offline.
        command = "${pkgs.bashInteractive}/bin/bash -l";
      };
    };
  };

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
      Open a terminal and try:

        portal-ada
            Opens a tmux split — your shell on one side, agent "ada"
            on the other, both in the same project directory.

        sudo machinectl shell ada@
            Drop into ada's session directly.

        From ada's shell, run:
            sudo whoami
            A zenity dialog should pop up on YOUR desktop asking to
            approve the sudo request. Approve it. ada gets root.
            Deny it. ada gets nothing.

        git log --author=ada
            ada has her own git identity. Anything she commits is
            signed by her, not you.

      The agent's home (/agents/ada) is wiped on every reboot. Only
      /agents/ada/projects survives (impermanence). Try it: leave a
      file in /agents/ada/foo and another in /agents/ada/projects/foo,
      then reboot.
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
