{ config, lib, pkgs, ... }:

let
  cfg = config.nuketown.approvalDaemon;
  xmppCfg = cfg.xmpp;

  socketPath = "/run/nuketown-broker/socket";

  escapeHtml = ''
    escape_html() {
      printf "%s\n" "$1" | ${pkgs.gnused}/bin/sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
    }
  '';

  runDir = "/run/nuketown-approval";

  # Renders a request directory (written by nuketown-approve, see
  # approval.nix) as Pango markup for the zenity dialog. Everything the
  # agent or the reviewer wrote is escaped; backslashes are doubled
  # because zenity unescapes \n etc. in --text.
  renderRequest = pkgs.writeText "nuketown-render-request.jq" ''
    def esc: gsub("\\\\"; "\\\\") | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
    def cut(n): if length > n then .[0:n] + "…" else . end;
    def bullets: map("\n  • " + (cut(300) | esc)) | join("");
    ($req[0]) as $r
    | (($rev[0]) // {status: "missing"}) as $v
    | "Agent <b>\($r.requester | esc)</b> wants to run as <b>\($r.run_as.user | esc)</b>:\n\n"
      + "<tt>\($r.display | cut(800) | esc)</tt>"
      + (if $r.why != "" then "\n\n<b>Agent's stated reason:</b> <i>\($r.why | cut(400) | esc)</i>" else "" end)
      + (if ($r.snapshots | length) > 0
         then "\n\n<b>Files</b> (snapshotted; the snapshot is what runs): "
              + ([$r.snapshots[] | (.path | esc) + (if .executed then " (runs)" else "" end)] | join(", "))
         else "" end)
      + "\n\n"
      + (if $v.status == "ok" then
           "<b>Reviewer</b>: risk <b>\($v.risk | ascii_upcase)</b>, recommends <b>\($v.recommendation | ascii_upcase)</b>\n"
           + ($v.summary | cut(1500) | esc)
           + (if ($v.notes | length) > 0 then "\n<b>Concerns:</b>" + ($v.notes | bullets) else "" end)
           + (if ($v.not_shown | length) > 0 then "\n<b>Could not verify:</b>" + ($v.not_shown | bullets) else "" end)
         elif $v.status == "disabled" then "<i>No reviewer configured.</i>"
         else "<b>No review</b>: " + (($v.reason // $v.status) | esc)
         end)
  '';

  # Default prompter: zenity, with a "Show files" button when the request
  # has snapshots. Exit 0 = approve.
  zenityPrompter = pkgs.writeShellScript "nuketown-zenity-prompter" ''
    set -uo pipefail
    DIR=$1
    TEXT=$(${pkgs.jq}/bin/jq -rn --slurpfile req "$DIR/request.json" \
      --slurpfile rev <(cat "$DIR/review.json" 2>/dev/null || true) \
      -f ${renderRequest}) || exit 1
    FILES=$(${pkgs.coreutils}/bin/mktemp)
    trap '${pkgs.coreutils}/bin/rm -f "$FILES"' EXIT
    NSNAP=0
    while IFS= read -r -d "" path && IFS= read -r -d "" snap && IFS= read -r -d "" sha; do
      [[ "$snap" == snapshots/* && "$snap" != *..* ]] || continue
      NSNAP=$((NSNAP + 1))
      printf '==== %s\n==== sha256 %s\n\n' "$path" "$sha" >> "$FILES"
      ${pkgs.coreutils}/bin/head -c 1048576 "$DIR/$snap" >> "$FILES"
      printf '\n\n' >> "$FILES"
    done < <(${pkgs.jq}/bin/jq -j '.snapshots[] | .path, "\u0000", .snapshot, "\u0000", .sha256, "\u0000"' "$DIR/request.json")
    EXTRA=()
    [ "$NSNAP" -gt 0 ] && EXTRA=(--extra-button "Show files")
    while true; do
      OUT=$(${pkgs.zenity}/bin/zenity --question \
        --title="Nuketown: Sudo Approval" \
        --text="$TEXT" \
        --ok-label="Approve" --cancel-label="Deny" --default-cancel \
        --width=640 --timeout=120 "''${EXTRA[@]}" 2>/dev/null)
      RC=$?
      [ $RC -eq 0 ] && exit 0
      if [ "$OUT" = "Show files" ]; then
        ${pkgs.zenity}/bin/zenity --text-info --title="Nuketown: files in this request" \
          --filename="$FILES" --width=900 --height=700 2>/dev/null
        continue
      fi
      exit 1
    done
  '';

  prompter = if cfg.prompter != null then cfg.prompter else "${zenityPrompter}";

  # ── Multi-op Broker Handler ─────────────────────────────────
  # Reads all ops from a connection, then decides how to fulfill them.
  # Only the nuketown-approval service user can connect (socket group).
  #   REQUEST:<id>            a sudo request; details in ${runDir}/<id>
  #   DECRYPT:<src>:<dest>    decrypt with the human's GPG key (YubiKey)
  # DECRYPT + REQUEST = combined flow: one popup, one YubiKey touch.
  brokerHandler = pkgs.writeShellScript "nuketown-broker-handler" ''
    set -uo pipefail
    ${escapeHtml}

    # ── Read all ops from the connection ──────────────────────
    DECRYPT_SRC=""
    DECRYPT_DEST=""
    REQ_ID=""

    while IFS= read -r REQUEST && [ -n "$REQUEST" ]; do
      OP=$(echo "$REQUEST" | ${pkgs.coreutils}/bin/cut -d: -f1)

      case "$OP" in
        DECRYPT)
          DECRYPT_SRC=$(echo "$REQUEST" | ${pkgs.coreutils}/bin/cut -d: -f2)
          DECRYPT_DEST=$(echo "$REQUEST" | ${pkgs.coreutils}/bin/cut -d: -f3)
          ;;
        REQUEST)
          REQ_ID=''${REQUEST#REQUEST:}
          if [[ ! "$REQ_ID" =~ ^[A-Za-z0-9._-]+$ ]] || [ ! -f "${runDir}/$REQ_ID/request.json" ]; then
            echo "ERROR: unknown request"
            exit 0
          fi
          ;;
        *)
          echo "ERROR: unknown operation"
          exit 0
          ;;
      esac
    done
    REQ_DIR="${runDir}/$REQ_ID"

    # ── Decide how to handle the request set ──────────────────

    # Custom prompter: ask first, then decrypt (one YubiKey touch).
    if [ -n "$REQ_ID" ] && [ ${if cfg.prompter != null then "1" else "0"} = 1 ]; then
      if ! ${prompter} "$REQ_DIR" < /dev/null > /dev/null 2>&1; then
        echo "DENIED"
        exit 0
      fi
      if [ -n "$DECRYPT_SRC" ]; then
        TMPFILE=$(${pkgs.coreutils}/bin/mktemp)
        trap 'rm -f "$TMPFILE"' EXIT
        if ! ${pkgs.gnupg}/bin/gpg -d "$DECRYPT_SRC" > "$TMPFILE" 2>/dev/null; then
          echo "DENIED"
          exit 0
        fi
        ${pkgs.coreutils}/bin/install -m 600 "$TMPFILE" "$DECRYPT_DEST"
      fi
      echo "APPROVED"
      exit 0
    fi

    # Combined: DECRYPT + REQUEST = one popup with command context, one YubiKey touch
    if [ -n "$DECRYPT_SRC" ] && [ -n "$REQ_ID" ]; then
      REQ_TEXT=$(${pkgs.jq}/bin/jq -rn --slurpfile req "$REQ_DIR/request.json" \
        --slurpfile rev <(cat "$REQ_DIR/review.json" 2>/dev/null || true) \
        -f ${renderRequest}) || { echo "ERROR: bad request"; exit 0; }

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
          --text="$REQ_TEXT\n\nThis requires unlocking secrets.\nTouch YubiKey to approve, or click Deny." \
          --ok-label="Approve" \
          --cancel-label="Deny" \
          --default-cancel \
          --width=640 \
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

    # REQUEST only (no decrypt)
    if [ -n "$REQ_ID" ]; then
      if ${prompter} "$REQ_DIR" < /dev/null > /dev/null 2>&1; then
        echo "APPROVED"
      else
        echo "DENIED"
      fi
      exit 0
    fi

    echo "ERROR: no valid operations"
  '';

  # ── XMPP Broker Client ──────────────────────────────────────
  # Standalone XMPP client that receives approval stanzas from agents
  # and shows zenity popups. Runs alongside the socket-based broker as
  # a parallel notification channel. First response wins.
  brokerXmppClient = pkgs.writers.writePython3Bin "nuketown-broker-xmpp" {
    libraries = [ pkgs.python3Packages.slixmpp ];
    flakeIgnore = [ "E501" "W503" ];
  } ''
    """Nuketown XMPP approval broker.

    Connects as the human's JID, advertises urn:nuketown:approval via
    service discovery, receives approval request stanzas from agents,
    shows zenity popups, and sends responses back.
    """
    import asyncio
    import logging
    import os
    import sys
    import uuid

    import slixmpp
    from slixmpp.xmlstream import ElementBase, register_stanza_plugin
    from slixmpp.xmlstream.handler import Callback
    from slixmpp.xmlstream.matcher import MatchXPath

    NAMESPACE = "urn:nuketown:approval"
    ZENITY = "${pkgs.zenity}/bin/zenity"
    DEFAULT_TIMEOUT = 120

    log = logging.getLogger("nuketown.broker.xmpp")


    # ── Custom Stanza Elements ──────────────────────────────────

    class ApprovalRequest(ElementBase):
        """Approval request stanza element."""
        name = "approval"
        namespace = NAMESPACE
        plugin_attrib = "approval"
        interfaces = {"id", "agent", "kind", "command", "timeout"}
        sub_interfaces = {"agent", "kind", "command", "timeout"}


    class ApprovalResponse(ElementBase):
        """Approval response stanza element."""
        name = "approval-response"
        namespace = NAMESPACE
        plugin_attrib = "approval_response"
        interfaces = {"id", "result"}
        sub_interfaces = {"result"}


    # ── Broker Bot ──────────────────────────────────────────────

    class ApprovalBroker(slixmpp.ClientXMPP):
        """XMPP client that handles approval requests via zenity."""

        def __init__(self, jid, password, resource="nuketown-broker"):
            full_jid = f"{jid}/{resource}"
            super().__init__(full_jid, password)

            self.register_plugin("xep_0030")  # Service discovery
            self.register_plugin("xep_0199")  # Ping

            register_stanza_plugin(slixmpp.Message, ApprovalRequest)
            register_stanza_plugin(slixmpp.Message, ApprovalResponse)

            self.add_event_handler("session_start", self.on_session_start)

            self.register_handler(
                Callback(
                    "Approval Request",
                    MatchXPath(f"{{jabber:client}}message/{{{NAMESPACE}}}approval"),
                    self._handle_approval,
                )
            )

        async def on_session_start(self, event):
            await self.get_roster()
            self.send_presence()

            # Advertise the approval feature via disco
            self["xep_0030"].add_feature(NAMESPACE)
            log.info("Session started, advertising %s", NAMESPACE)

        def _handle_approval(self, msg):
            """Dispatch approval request to async handler."""
            asyncio.ensure_future(self._process_approval(msg))

        async def _process_approval(self, msg):
            """Show zenity popup and send response."""
            approval = msg["approval"]
            req_id = approval["id"] or str(uuid.uuid4())[:8]
            agent = approval["agent"] or "unknown"
            kind = approval["kind"] or "unknown"
            command = approval["command"] or ""
            try:
                timeout = int(approval["timeout"] or DEFAULT_TIMEOUT)
            except (ValueError, TypeError):
                timeout = DEFAULT_TIMEOUT

            log.info(
                "Approval request %s from %s: %s %s",
                req_id, agent, kind, command,
            )

            # Build zenity command
            if kind == "sudo":
                text = (
                    f"Agent <b>{agent}</b> wants to run:\\n\\n"
                    f"<tt>{command}</tt>\\n\\n"
                    f"Approve?"
                )
                title = f"Nuketown: {agent} ({kind})"
            else:
                text = (
                    f"Agent <b>{agent}</b> requests <b>{kind}</b>:\\n\\n"
                    f"<tt>{command}</tt>\\n\\n"
                    f"Approve?"
                )
                title = f"Nuketown: {agent} ({kind})"

            try:
                proc = await asyncio.wait_for(
                    asyncio.create_subprocess_exec(
                        ZENITY,
                        "--question",
                        f"--title={title}",
                        f"--text={text}",
                        "--ok-label=Approve",
                        "--cancel-label=Deny",
                        "--default-cancel",
                        "--width=500",
                        env={**os.environ, "DISPLAY": os.environ.get("DISPLAY", ":0")},
                    ),
                    timeout=5,
                )
                rc = await asyncio.wait_for(proc.wait(), timeout=timeout)
                result = "approved" if rc == 0 else "denied"
            except asyncio.TimeoutError:
                result = "denied"
                log.warning("Approval request %s timed out", req_id)
            except Exception as e:
                result = "denied"
                log.error("Zenity failed for request %s: %s", req_id, e)

            log.info("Approval request %s: %s", req_id, result)

            # Send response back to the requesting agent
            resp = self.make_message(mto=msg["from"], mtype="normal")
            resp["approval_response"]["id"] = req_id
            resp["approval_response"]["result"] = result
            resp.send()


    def main():
        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s %(name)s %(levelname)s %(message)s",
        )

        jid = os.environ.get("NUKETOWN_XMPP_JID")
        password_file = os.environ.get("NUKETOWN_XMPP_PASSWORD_FILE")
        resource = os.environ.get("NUKETOWN_XMPP_RESOURCE", "nuketown-broker")

        if not jid:
            log.error("NUKETOWN_XMPP_JID not set")
            sys.exit(1)
        if not password_file:
            log.error("NUKETOWN_XMPP_PASSWORD_FILE not set")
            sys.exit(1)

        try:
            with open(password_file) as f:
                password = f.read().strip()
        except FileNotFoundError:
            log.error("Password file not found: %s", password_file)
            sys.exit(1)

        bot = ApprovalBroker(jid, password, resource)
        bot.connect()
        bot.process(forever=True)


    if __name__ == "__main__":
        main()
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

    prompter = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Command that asks the human about a sudo request. It gets the
        request directory (request.json, review.json, snapshots/) as its
        only argument and exits 0 to approve, anything else to deny.
        null uses the built-in zenity dialog. With a custom prompter, a
        decrypt (sudoex --decrypt) runs after approval.
      '';
    };

    xmpp = {
      enable = lib.mkEnableOption "XMPP client for the approval broker";

      jid = lib.mkOption {
        type = lib.types.str;
        description = "Human's XMPP JID (e.g. josh@6bit.com)";
      };

      resource = lib.mkOption {
        type = lib.types.str;
        default = "nuketown-broker";
        description = "XMPP resource identifier for the broker session";
      };

      passwordFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to file containing the XMPP password";
      };
    };
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

    systemd.user.services.nuketown-broker-xmpp = lib.mkIf xmppCfg.enable {
      Unit = {
        Description = "Nuketown XMPP approval broker";
        After = [ "graphical-session.target" "nuketown-broker.service" ];
      };

      Service = {
        Type = "simple";
        ExecStart = "${brokerXmppClient}/bin/nuketown-broker-xmpp";
        Restart = "always";
        RestartSec = 10;
        Environment = [
          "DISPLAY=:0"
          "NUKETOWN_XMPP_JID=${xmppCfg.jid}"
          "NUKETOWN_XMPP_PASSWORD_FILE=${xmppCfg.passwordFile}"
          "NUKETOWN_XMPP_RESOURCE=${xmppCfg.resource}"
        ];
      };

      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
