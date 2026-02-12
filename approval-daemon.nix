{ config, lib, pkgs, ... }:

let
  cfg = config.nuketown.approvalDaemon;

  socketPath = "/run/nuketown-broker/socket";

  escapeHtml = ''
    escape_html() {
      echo "$1" | ${pkgs.gnused}/bin/sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
    }
  '';

  # ── Multi-op Broker Handler ─────────────────────────────────
  # Reads all ops from a connection, then decides how to fulfill them.
  # A DECRYPT + SUDO = combined flow: one popup, one YubiKey touch.
  brokerHandler = pkgs.writeShellScript "nuketown-broker-handler" ''
    set -uo pipefail
    ${escapeHtml}

    # ── Read all ops from the connection ──────────────────────
    DECRYPT_SRC=""
    DECRYPT_DEST=""
    SUDO_USER=""
    SUDO_COMMAND=""
    LEGACY_LINES=()

    while IFS= read -r REQUEST && [ -n "$REQUEST" ]; do
      OP=$(echo "$REQUEST" | ${pkgs.coreutils}/bin/cut -d: -f1)

      case "$OP" in
        DECRYPT)
          DECRYPT_SRC=$(echo "$REQUEST" | ${pkgs.coreutils}/bin/cut -d: -f2)
          DECRYPT_DEST=$(echo "$REQUEST" | ${pkgs.coreutils}/bin/cut -d: -f3)
          ;;
        SUDO)
          SUDO_USER=$(echo "$REQUEST" | ${pkgs.coreutils}/bin/cut -d: -f2)
          SUDO_COMMAND=$(echo "$REQUEST" | ${pkgs.coreutils}/bin/cut -d: -f3-)
          ;;
        *)
          # Legacy: username:command
          SUDO_USER=$(echo "$REQUEST" | ${pkgs.coreutils}/bin/cut -d: -f1)
          SUDO_COMMAND=$(echo "$REQUEST" | ${pkgs.coreutils}/bin/cut -d: -f2-)
          ;;
      esac
    done

    # ── Decide how to handle the request set ──────────────────

    # Combined: DECRYPT + SUDO = one popup with command context, one YubiKey touch
    if [ -n "$DECRYPT_SRC" ] && [ -n "$SUDO_USER" ]; then
      USER_ESC=$(escape_html "$SUDO_USER")
      COMMAND_ESC=$(escape_html "$SUDO_COMMAND")

      TMPFILE=$(${pkgs.coreutils}/bin/mktemp)
      cleanup() {
        rm -f "$TMPFILE" 2>/dev/null || true
      }
      trap cleanup EXIT

      # Start gpg in background (blocks on YubiKey touch)
      ${pkgs.gnupg}/bin/gpg -d "$DECRYPT_SRC" > "$TMPFILE" 2>/dev/null &
      GPG_PID=$!

      # Single popup showing exactly what will happen
      ${pkgs.zenity}/bin/zenity \
          --question \
          --title="Nuketown: Approval" \
          --text="Agent <b>$USER_ESC</b> wants to run:\n\n<tt>$COMMAND_ESC</tt>\n\nThis requires unlocking secrets.\nTouch YubiKey to approve, or click Deny." \
          --ok-label="Approve" \
          --cancel-label="Deny" \
          --default-cancel \
          --width=500 \
          2>/dev/null &
      ZENITY_PID=$!

      GPG_DONE=""
      GPG_OK=""

      while true; do
        # Check if gpg finished
        if [ -z "$GPG_DONE" ] && ! kill -0 "$GPG_PID" 2>/dev/null; then
          wait "$GPG_PID" 2>/dev/null
          GPG_RC=$?
          GPG_DONE=1
          [ "$GPG_RC" -eq 0 ] && GPG_OK=1

          if [ -n "$GPG_OK" ]; then
            # YubiKey touched — approve everything
            kill "$ZENITY_PID" 2>/dev/null || true
            wait "$ZENITY_PID" 2>/dev/null || true
            ${pkgs.coreutils}/bin/install -m 600 "$TMPFILE" "$DECRYPT_DEST"
            echo "APPROVED"
            exit 0
          fi
        fi

        # Check if zenity finished
        if ! kill -0 "$ZENITY_PID" 2>/dev/null; then
          wait "$ZENITY_PID" 2>/dev/null
          ZENITY_RC=$?

          if [ "$ZENITY_RC" -eq 0 ]; then
            # Approve clicked
            if [ -z "$GPG_DONE" ]; then
              # GPG still running — wait for YubiKey touch
              wait "$GPG_PID" 2>/dev/null
              GPG_RC=$?
              GPG_DONE=1
              [ "$GPG_RC" -eq 0 ] && GPG_OK=1
            fi

            if [ -n "$GPG_OK" ]; then
              ${pkgs.coreutils}/bin/install -m 600 "$TMPFILE" "$DECRYPT_DEST"
              echo "APPROVED"
              exit 0
            fi

            # GPG failed (YubiKey timed out) — retry loop
            while true; do
              ${pkgs.gnupg}/bin/gpg -d "$DECRYPT_SRC" > "$TMPFILE" 2>/dev/null &
              GPG_PID=$!

              ${pkgs.zenity}/bin/zenity \
                  --question \
                  --title="Nuketown: Retry" \
                  --text="YubiKey timed out.\\n\\nTouch YubiKey to retry, or click Deny to abort." \
                  --ok-label="Retry" \
                  --cancel-label="Deny" \
                  --default-cancel \
                  --width=400 \
                  2>/dev/null &
              RETRY_PID=$!

              while true; do
                if ! kill -0 "$GPG_PID" 2>/dev/null; then
                  wait "$GPG_PID" 2>/dev/null
                  GPG_RC=$?
                  if [ "$GPG_RC" -eq 0 ]; then
                    kill "$RETRY_PID" 2>/dev/null || true
                    wait "$RETRY_PID" 2>/dev/null || true
                    ${pkgs.coreutils}/bin/install -m 600 "$TMPFILE" "$DECRYPT_DEST"
                    echo "APPROVED"
                    exit 0
                  fi
                  # GPG failed again — break inner loop, will show retry dialog again or exit
                  kill "$RETRY_PID" 2>/dev/null || true
                  wait "$RETRY_PID" 2>/dev/null || true
                  break
                fi

                if ! kill -0 "$RETRY_PID" 2>/dev/null; then
                  wait "$RETRY_PID" 2>/dev/null
                  RETRY_RC=$?
                  if [ "$RETRY_RC" -eq 0 ]; then
                    # Retry clicked — wait for current GPG attempt
                    wait "$GPG_PID" 2>/dev/null
                    GPG_RC=$?
                    if [ "$GPG_RC" -eq 0 ]; then
                      ${pkgs.coreutils}/bin/install -m 600 "$TMPFILE" "$DECRYPT_DEST"
                      echo "APPROVED"
                      exit 0
                    fi
                    break  # GPG failed, outer loop retries
                  else
                    # Deny clicked
                    kill "$GPG_PID" 2>/dev/null || true
                    wait "$GPG_PID" 2>/dev/null || true
                    echo "DENIED"
                    exit 0
                  fi
                fi

                sleep 0.1
              done
            done
          else
            # Deny clicked
            kill "$GPG_PID" 2>/dev/null || true
            wait "$GPG_PID" 2>/dev/null || true
            echo "DENIED"
            exit 0
          fi
        fi

        sleep 0.1
      done
    fi

    # DECRYPT only (no sudo)
    if [ -n "$DECRYPT_SRC" ]; then
      SRC_ESC=$(escape_html "$DECRYPT_SRC")

      TMPFILE=$(${pkgs.coreutils}/bin/mktemp)
      cleanup() { rm -f "$TMPFILE" 2>/dev/null || true; }
      trap cleanup EXIT

      ${pkgs.zenity}/bin/zenity \
          --info \
          --title="Nuketown: Decrypt" \
          --text="Touch YubiKey to decrypt:\n\n<tt>$SRC_ESC</tt>" \
          --ok-label="Cancel" \
          --width=400 \
          2>/dev/null &
      ZENITY_PID=$!

      if ${pkgs.gnupg}/bin/gpg -d "$DECRYPT_SRC" > "$TMPFILE" 2>/dev/null; then
        kill $ZENITY_PID 2>/dev/null || true
        wait $ZENITY_PID 2>/dev/null || true
        ${pkgs.coreutils}/bin/install -m 600 "$TMPFILE" "$DECRYPT_DEST"
        echo "DECRYPTED"
      else
        kill $ZENITY_PID 2>/dev/null || true
        wait $ZENITY_PID 2>/dev/null || true
        echo "DENIED"
      fi
      exit 0
    fi

    # SUDO only (no decrypt)
    if [ -n "$SUDO_USER" ]; then
      USER_ESC=$(escape_html "$SUDO_USER")
      COMMAND_ESC=$(escape_html "$SUDO_COMMAND")

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
      exit 0
    fi

    echo "ERROR: no valid operations"
  '';

  brokerDaemon = pkgs.writeShellScript "nuketown-broker-daemon" ''
    set -euo pipefail

    SOCKET_PATH="${socketPath}"

    ${pkgs.coreutils}/bin/rm -f "$SOCKET_PATH"

    echo "Starting Nuketown operation broker on $SOCKET_PATH"

    ${pkgs.socat}/bin/socat \
      UNIX-LISTEN:"$SOCKET_PATH",fork,mode=660 \
      EXEC:"${brokerHandler}"
  '';

in
{
  options.nuketown.approvalDaemon = {
    enable = lib.mkEnableOption "Nuketown operation broker";
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.nuketown-broker = {
      Unit = {
        Description = "Nuketown operation broker";
        After = [ "graphical-session.target" ];
      };

      Service = {
        Type = "simple";
        ExecStart = "${brokerDaemon}";
        Restart = "always";
        RestartSec = 5;
        Environment = "DISPLAY=:0";
      };

      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
