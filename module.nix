{ config, lib, pkgs, ... }:

let
  cfg = config.nuketown;

  # ── Sudo Approval Infrastructure ────────────────────────────────
  # Three layers:
  # 1. Per-agent: shadow sudo binary in home-manager that calls the wrapper
  # 2. System: wrapper that connects to approval socket and execs on approval
  # 3. User service: daemon under the human's X session showing zenity dialogs

  socketPath = "/run/sudo-approval/socket";

  approvalWrapper = pkgs.writeShellScriptBin "sudo-with-approval" ''
    set -e

    SOCKET_PATH="${socketPath}"
    REQUESTING_USER="''${SUDO_USER:-$(whoami)}"
    COMMAND="$*"

    if [ -z "$COMMAND" ]; then
      echo "Usage: sudo sudo-with-approval <command>" >&2
      exit 1
    fi

    if [ ! -S "$SOCKET_PATH" ]; then
      echo "Error: Approval daemon is not running (socket not found at $SOCKET_PATH)" >&2
      exit 1
    fi

    echo "Requesting approval to run: $COMMAND" >&2

    # Send request to daemon and wait for response
    # Username:command format — usernames can't contain colons on Unix
    RESPONSE=$(printf "%s\n" "$REQUESTING_USER:$COMMAND" | ${pkgs.socat}/bin/socat STDIO,ignoreeof UNIX-CONNECT:"$SOCKET_PATH" || echo "ERROR")

    if [ "$RESPONSE" = "APPROVED" ]; then
      echo "Approved! Executing command..." >&2
      exec "$@"
    elif [ "$RESPONSE" = "DENIED" ]; then
      echo "Request denied." >&2
      exit 1
    else
      echo "Error communicating with approval daemon (got: '$RESPONSE')" >&2
      exit 1
    fi
  '';

  approvalHandler = pkgs.writeShellScript "sudo-approval-handler" ''
    read -r REQUEST

    USER=$(echo "$REQUEST" | cut -d: -f1)
    COMMAND=$(echo "$REQUEST" | cut -d: -f2-)

    # Escape HTML entities for zenity markup
    USER_ESC=$(echo "$USER" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    COMMAND_ESC=$(echo "$COMMAND" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

    if ${pkgs.zenity}/bin/zenity \
        --question \
        --title="Nuketown: Sudo Approval" \
        --text="Agent <b>$USER_ESC</b> wants to run:\n\n<tt>$COMMAND_ESC</tt>\n\nApprove?" \
        --ok-label="Approve" \
        --cancel-label="Deny" \
        --default-cancel \
        --width=500 \
        --timeout=60 \
        2>/dev/null; then
      echo "APPROVED"
    else
      echo "DENIED"
    fi
  '';

  approvalDaemon = pkgs.writeShellScript "sudo-approval-daemon" ''
    set -euo pipefail

    SOCKET_PATH="${socketPath}"
    mkdir -p "$(dirname "$SOCKET_PATH")"
    chmod 755 "$(dirname "$SOCKET_PATH")"
    rm -f "$SOCKET_PATH"

    echo "Starting Nuketown sudo approval daemon on $SOCKET_PATH"

    ${pkgs.socat}/bin/socat \
      UNIX-LISTEN:"$SOCKET_PATH",fork,mode=666 \
      EXEC:"${approvalHandler}"
  '';

  # Shadow sudo binary for agents — redirects to the approval wrapper
  sudoShim = pkgs.writeShellScriptBin "sudo" ''
    exec /run/wrappers/bin/sudo sudo-with-approval "$@"
  '';

  # ── Agent Options ───────────────────────────────────────────────

  agentOpts = { name, config, ... }: {
    options = {
      enable = lib.mkEnableOption "Nuketown agent ${name}";

      uid = lib.mkOption {
        type = lib.types.int;
        description = "UID for the agent user";
      };

      role = lib.mkOption {
        type = lib.types.str;
        default = "general";
        description = "Short role description (software, research, ops, etc.)";
      };

      description = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Agent's self-knowledge — who they are, how they work";
      };

      git = {
        name = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Git author name";
        };
        email = lib.mkOption {
          type = lib.types.str;
          default = "${name}@${cfg.domain}";
          description = "Git author email";
        };
        signing = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Sign commits with GPG";
        };
      };

      packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [];
        description = "Additional packages for this agent";
      };

      extraHomeConfig = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "Additional home-manager configuration merged into the agent's home";
      };

      persist = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "projects" ];
        description = "Directories under the agent's home to persist across reboots";
      };

      secrets = {
        sshKey = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "sops secret name for SSH private key";
        };
        gpgKey = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "sops secret name for GPG private key";
        };
        extraSecrets = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
          description = "Additional sops secrets as { name = sopsSecretName; }";
        };
      };

      devices = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            subsystem = lib.mkOption { type = lib.types.str; };
            attrs = lib.mkOption { type = lib.types.attrsOf lib.types.str; };
            action = lib.mkOption {
              type = lib.types.str;
              default = "add|bind";
              description = ''
                Udev action to match. Use "add|bind" for USB devices that
                re-enumerate (e.g. serial-to-DFU transitions). Use "add"
                for tty devices that only appear once.
              '';
            };
            permission = lib.mkOption {
              type = lib.types.str;
              default = "rw";
            };
            group = lib.mkOption {
              type = lib.types.str;
              default = "plugdev";
              description = "Group ownership for the device node";
            };
          };
        });
        default = [];
        description = "Udev device access rules for this agent";
      };

      sudo = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Allow agent to request sudo via interactive approval.
            The agent's sudo binary is shimmed to route through the
            approval daemon, which pops a zenity dialog on the
            human's desktop. The agent never gets a password.
          '';
        };
        commands = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = ''
            Specific commands the agent is allowed to sudo.
            Empty list = can request approval for any command.
          '';
        };
      };

      portal = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Generate a tmux portal command for this agent.
            Opens a tmux window with the agent running in the top pane
            and your shell in the bottom pane, both in the project dir.
          '';
        };
        command = lib.mkOption {
          type = lib.types.str;
          default = "${pkgs.unstable.claude-code}/bin/claude --dangerously-skip-permissions";
          description = ''
            Command to run as the agent in the top pane.
            Defaults to claude-code via direct store path. Replace
            with a custom shell agent when you build one.
          '';
        };
        layout = lib.mkOption {
          type = lib.types.str;
          default = "75/25";
          description = "Pane split ratio (agent/human). '75/25' or '50/50'.";
        };
      };
    };
  };

  enabledAgents = lib.filterAttrs (_: a: a.enable) cfg.agents;
  sudoAgents = lib.filterAttrs (_: a: a.enable && a.sudo.enable) cfg.agents;

  # ── Udev Rules ──────────────────────────────────────────────────

  mkUdevRules = lib.concatStringsSep "\n" (lib.concatLists (lib.mapAttrsToList (name: agent:
    map (dev:
      let
        # ATTRS walks up the device tree (for matching parent USB device
        # attributes from a tty node). ATTR matches on the device itself
        # (correct when SUBSYSTEM matches the level the attribute lives on).
        useAttrs = dev.subsystem == "tty";
        attrStr = lib.concatStringsSep ", " (lib.mapAttrsToList (k: v:
          if useAttrs
          then ''ATTRS{${k}}=="${v}"''
          else ''ATTR{${k}}=="${v}"''
        ) dev.attrs);
        # Use $env{DEVNAME} — works reliably across tty and usb subsystems.
        # MODE/GROUP and RUN+= must be on the same line to avoid stepping on each other.
      in
      ''SUBSYSTEM=="${dev.subsystem}", ACTION=="${dev.action}", ${attrStr}, MODE="0660", GROUP="${dev.group}", RUN+="${pkgs.acl}/bin/setfacl -m u:${name}:${dev.permission} $env{DEVNAME}"''
    ) agent.devices
  ) enabledAgents));

in
{
  options.nuketown = {
    enable = lib.mkEnableOption "Nuketown agent framework";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "${config.networking.hostName}.local";
      description = "Domain for agent email addresses";
    };

    agentsDir = lib.mkOption {
      type = lib.types.str;
      default = "/agents";
      description = "Base directory for agent homes";
    };

    btrfsDevice = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "UUID of btrfs device for ephemeral agent homes";
    };

    sopsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Default sops file for agent secrets";
    };

    basePackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [ git ripgrep fd jq curl tree ];
      description = "Packages available to all agents";
    };

    agents = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule agentOpts);
      default = {};
      description = "Agent definitions";
    };

    projectDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "~/dev" ];
      description = "Directories to search for projects (used by portal fzf)";
    };
  };

  config = lib.mkIf cfg.enable {

    # ── Portal Scripts ───────────────────────────────────────────
    # Per-agent tmux portal: fzf pick a project, open a window with
    # the agent in the top pane and your shell in the bottom.

    environment.systemPackages =
      (lib.optional (sudoAgents != {}) approvalWrapper)
      ++ lib.concatLists (lib.mapAttrsToList (name: agent:
        lib.optional agent.portal.enable (
          let
            splitPercent = let
              parts = lib.splitString "/" agent.portal.layout;
            in lib.elemAt parts 1;

            # Helper: shell into the agent via machinectl with a login
            # environment, cd to the project, and exec the agent command.
            # bash -l loads the agent's full home-manager profile via PAM.
            agentLauncher = pkgs.writeShellScript "portal-launcher-${name}" ''
              path="$1"
              shift
              exec sudo ${pkgs.systemd}/bin/machinectl shell ${name}@ ${pkgs.bash}/bin/bash -l -c "cd '$path' && exec ${agent.portal.command} $*"
            '';
          in
          pkgs.writeShellScriptBin "portal-${name}" ''
            # Portal into ${name}'s workspace
            # Usage: portal-${name} [path]
            #   path: optional project directory (fzf picker if omitted)

            path=$1
            if [ "$#" -eq 0 ]; then
              selection=$(find ${lib.concatMapStringsSep " " (d: ''"${d}"'') cfg.projectDirs} \
                -maxdepth 2 -type d -not -path '*/.*' -printf '%P\n' 2>/dev/null | \
                ${pkgs.fzf}/bin/fzf --prompt="${name}> ")
              [[ -z "$selection" ]] && exit 1
              # Resolve the full path from whichever projectDir matched
              for dir in ${lib.concatMapStringsSep " " (d: ''"${d}"'') cfg.projectDirs}; do
                if [ -d "$dir/$selection" ]; then
                  path="$dir/$selection"
                  break
                fi
              done
              if [ -z "$path" ]; then
                echo "Could not resolve path for $selection" >&2
                exit 1
              fi
            fi

            wname=$(basename "$path")

            ${pkgs.tmux}/bin/tmux new-window -c "$path" -n "$wname"
            ${pkgs.tmux}/bin/tmux send-keys "${agentLauncher} \"$path\"" C-m
            ${pkgs.tmux}/bin/tmux split-window -v -l ${splitPercent}% -c "$path"
            ${pkgs.tmux}/bin/tmux last-pane
          ''
        )
      ) enabledAgents)

      # Generic portal: pick an agent, then a project
      ++ (let
        portalAgents = lib.filterAttrs (_: a: a.enable && a.portal.enable) cfg.agents;
      in lib.optional (portalAgents != {}) (
        pkgs.writeShellScriptBin "portal" ''
          # Portal into an agent's workspace
          # Usage: portal [agent] [path]

          agent=$1
          if [ -z "$agent" ]; then
            agent=$(printf '%s\n' ${lib.concatMapStringsSep " " (n: ''"${n}"'') (lib.attrNames portalAgents)} | \
              ${pkgs.fzf}/bin/fzf --prompt="agent> ")
            [[ -z "$agent" ]] && exit 1
          else
            shift
          fi

          exec "portal-$agent" "$@"
        ''
      ));

    # ── Users ────────────────────────────────────────────────────
    users.users = lib.mapAttrs (name: agent: {
      uid = agent.uid;
      group = name;
      isNormalUser = true;
      home = "${cfg.agentsDir}/${name}";
      shell = pkgs.bash;
      extraGroups = [];
    }) enabledAgents;

    users.groups = lib.mapAttrs (name: agent: {
      gid = agent.uid;
    }) enabledAgents;

    # ── Home Manager ─────────────────────────────────────────────
    home-manager.users = lib.mapAttrs (name: agent:
      lib.recursiveUpdate {
        home.username = name;
        home.homeDirectory = lib.mkForce "${cfg.agentsDir}/${name}";
        home.stateVersion = config.system.stateVersion;

        home.packages = cfg.basePackages ++ agent.packages
          # Shadow sudo with approval shim for agents with sudo enabled
          ++ lib.optional agent.sudo.enable sudoShim;

        programs.bash = {
          enable = true;
          sessionVariables = {
            EDITOR = "vim";
          };
        };

        programs.git = {
          enable = true;
          signing.signByDefault = agent.git.signing;
          settings = {
            user.name = agent.git.name;
            user.email = agent.git.email;
            init.defaultBranch = "master";
            pull.rebase = true;
            safe.directory = "*";
          };
        };

        programs.direnv = {
          enable = true;
          enableBashIntegration = true;
          nix-direnv.enable = true;
        };

        xdg.configFile."nuketown/identity.toml".text = ''
          name = "${agent.git.name}"
          role = "${agent.role}"
          domain = "${cfg.domain}"

          [description]
          text = """
          ${agent.description}
          """
        '';
      } agent.extraHomeConfig
    ) enabledAgents;

    # ── Filesystem ───────────────────────────────────────────────
    fileSystems.${cfg.agentsDir} = lib.mkIf (cfg.btrfsDevice != null) {
      device = "/dev/disk/by-uuid/${cfg.btrfsDevice}";
      fsType = "btrfs";
      options = [ "subvol=@agents" "noatime" ];
    };

    boot.initrd.systemd.services.rollback-agents = lib.mkIf (cfg.btrfsDevice != null) {
      description = "Rollback ${cfg.agentsDir} to blank snapshot";
      wantedBy = [ "initrd.target" ];
      after = [ "cryptsetup.target" ];
      before = [ "sysroot.mount" ];
      unitConfig.DefaultDependencies = "no";
      serviceConfig.Type = "oneshot";
      script = ''
        mkdir -p /mnt
        mount -t btrfs -o subvol=/ /dev/disk/by-uuid/${cfg.btrfsDevice} /mnt
        if [ -e /mnt/@agents ]; then
          btrfs subvolume delete /mnt/@agents
        fi
        btrfs subvolume snapshot /mnt/@agents-blank /mnt/@agents
        umount /mnt
      '';
    };

    # ── Impermanence ─────────────────────────────────────────────
    environment.persistence."/persist" = {
      users = lib.mapAttrs (name: agent: {
        directories = agent.persist;
      }) enabledAgents;
    };

    # ── Secrets ──────────────────────────────────────────────────
    sops.secrets = lib.mkMerge (lib.mapAttrsToList (name: agent:
      let
        sopsFile = cfg.sopsFile;
      in
      lib.optionalAttrs (agent.secrets.sshKey != null) {
        "${agent.secrets.sshKey}" = {
          inherit sopsFile;
          owner = name;
          path = "${cfg.agentsDir}/${name}/.ssh/id_ed25519";
        };
      }
      // lib.optionalAttrs (agent.secrets.gpgKey != null) {
        "${agent.secrets.gpgKey}" = {
          inherit sopsFile;
          owner = name;
        };
      }
      // lib.mapAttrs' (secretName: sopsName: lib.nameValuePair sopsName {
        inherit sopsFile;
        owner = name;
      }) agent.secrets.extraSecrets
    ) enabledAgents);

    # ── Udev ─────────────────────────────────────────────────────
    services.udev.extraRules = lib.mkIf (mkUdevRules != "") mkUdevRules;

    # ── Sudo Approval System ─────────────────────────────────────

    # Allow agents to run the approval wrapper via sudo without a password.
    # The wrapper itself gates execution behind the zenity approval dialog.
    security.sudo.extraRules = lib.concatLists (lib.mapAttrsToList (name: agent:
      lib.optional agent.sudo.enable {
        users = [ name ];
        runAs = "root:root";
        commands =
          if agent.sudo.commands == []
          then [{
            command = "/run/current-system/sw/bin/sudo-with-approval";
            options = [ "NOPASSWD" "SETENV" ];
          }]
          else map (cmd: {
            command = cmd;
            options = [ "NOPASSWD" "SETENV" ];
          }) agent.sudo.commands;
      }
    ) enabledAgents);

    # Socket directory for the approval daemon
    # Owned by the human user who runs the daemon service
    # For now assumes uid 1000; TODO: make human user configurable
    systemd.tmpfiles.rules = lib.mkIf (sudoAgents != {}) (
      let humanUid = toString (config.users.users."human".uid or 1000);
      in [
        "d /run/sudo-approval 0755 ${humanUid} ${humanUid} -"
      ]
    );

    # The approval daemon runs as a user service under the human's
    # session so it has access to the X11/Wayland display for zenity.
    # Enabled via home-manager for the human user, or manually:
    #   systemctl --user start sudo-approval-daemon
    #
    # Nuketown provides the service unit but doesn't know which user
    # is "the human" — import nuketown.homeManagerModules.approvalDaemon
    # in the human's home-manager config.
  };
}
