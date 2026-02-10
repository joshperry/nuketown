# Example: declaring agents and the approval daemon
{ pkgs, lib, ... }:
{
  imports = [ ./module.nix ];

  nuketown = {
    enable = true;
    domain = "signi.local";
    btrfsDevice = "38b243a0-c875-4758-8998-cc6c6a4c451e";
    sopsFile = ./secrets/agents.yaml;
    projectDirs = [ "~/dev" ];
    humanUser = "josh";  # Required when agents have sudo.enable = true

    agents.ada = {
      enable = true;
      uid = 1100;
      role = "software";
      description = ''
        Software collaborator. Thinks before acting.
        Prefers to understand the domain deeply before
        proposing solutions. Works on embedded systems,
        NixOS configuration, and web projects.
      '';

      packages = with pkgs; [
        unstable.claude-code
        gcc-arm-embedded
        stm32flash
        dfu-util
      ];

      persist = [
        "projects"
        ".config/claude"
      ];

      secrets.sshKey = "ada/ssh-key";
      secrets.gpgKey = "ada/gpg-key";

      sudo.enable = true;

      portal = {
        enable = true;
        # Default command is claude-code via nix store path.
        # Replace with shell agent later:
        # command = "${pkgs.ada-shell}/bin/ada-shell";
      };

      devices = [
        {
          # STM32 flight controllers (VCP serial mode)
          subsystem = "tty";
          action = "add";
          attrs = { idVendor = "0483"; idProduct = "5740"; };
        }
        {
          # STM32 bootloader (DFU — re-enumerates from serial, needs add|bind)
          subsystem = "usb";
          attrs = { product = "STM32  BOOTLOADER"; };
        }
        {
          # DFU in FS Mode
          subsystem = "usb";
          attrs = { product = "DFU in FS Mode"; };
        }
      ];

      claudeCode = {
        enable = true;
        settings.permissions = {
          defaultMode = "allowEdits";
          additionalDirectories = [ "/home/josh/dev" ];
        };
        # Extra context appended to the auto-generated agent prompt
        extraPrompt = ''
          ## NixOS Workflow

          To build and apply system configuration changes:
          1. `nixos-rebuild build --flake . --show-trace`
          2. `nvd diff /run/current-system result`
          3. `sudo sh -c 'nix-env -p /nix/var/nix/profiles/system --set ./result && ./result/bin/switch-to-configuration switch'`
          4. `unlink result`
        '';
      };

      extraHomeConfig = {
        programs.neovim = {
          enable = true;
          vimAlias = true;
          defaultEditor = true;
        };
      };
    };

    agents.vox = {
      enable = true;
      uid = 1101;
      role = "research";
      description = ''
        Research agent. Reads papers, summarizes findings,
        digs into topics. Web access, no hardware.
      '';

      packages = with pkgs; [
        unstable.claude-code
        python3
      ];

      persist = [
        "projects"
        "notes"
      ];

      secrets.sshKey = "vox/ssh-key";

      # No sudo — vox doesn't need it

      # claudeCode.enable = true would auto-generate a "vox-research"
      # agent definition. Off by default — enable per-agent as needed.
    };
  };

  # ── The human's config ────────────────────────────────────────
  # In your home-manager users block:
  #
  #   home-manager.users.josh = {
  #     imports = [
  #       ./users/josh
  #       ./nuketown/approval-daemon.nix  # ← add this
  #     ];
  #
  #     nuketown.approvalDaemon.enable = true;
  #   };
  #
  # This runs the zenity approval daemon under josh's graphical
  # session. When ada runs `sudo`, josh sees the popup.
}
