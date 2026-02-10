{ config, lib, pkgs, ... }:

let
  cfg = config.nuketown.approvalDaemon;

  socketPath = "/run/sudo-approval/socket";

  approvalHandler = pkgs.writeShellScript "sudo-approval-handler" ''
    read -r REQUEST

    USER=$(echo "$REQUEST" | ${pkgs.coreutils}/bin/cut -d: -f1)
    COMMAND=$(echo "$REQUEST" | ${pkgs.coreutils}/bin/cut -d: -f2-)

    # Escape HTML entities for zenity markup
    USER_ESC=$(echo "$USER" | ${pkgs.gnused}/bin/sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    COMMAND_ESC=$(echo "$COMMAND" | ${pkgs.gnused}/bin/sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

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
    # Directory is created by systemd tmpfiles, just clean up old socket
    ${pkgs.coreutils}/bin/rm -f "$SOCKET_PATH"

    echo "Starting Nuketown sudo approval daemon on $SOCKET_PATH"

    ${pkgs.socat}/bin/socat \
      UNIX-LISTEN:"$SOCKET_PATH",fork,mode=666 \
      EXEC:"${approvalHandler}"
  '';

in
{
  options.nuketown.approvalDaemon = {
    enable = lib.mkEnableOption "Nuketown sudo approval daemon";
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.sudo-approval-daemon = {
      Unit = {
        Description = "Nuketown sudo approval daemon";
        After = [ "graphical-session.target" ];
      };

      Service = {
        Type = "simple";
        ExecStart = "${approvalDaemon}";
        Restart = "always";
        RestartSec = 5;
      };

      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
