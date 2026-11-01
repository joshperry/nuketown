{ config, lib, pkgs, ... }:

let
  cfg = config.nuketown.approvalDaemon;
  xmppCfg = cfg.xmpp;

  socketPath = "/run/nuketown-broker/socket";

  runDir = "/run/nuketown-approval";

  # Renders a request directory (written by nuketown-approve, see
  # approval.nix) as Pango markup, for zenity-style custom prompters
  # (cfg.renderer; the built-in card renders request.json itself). Everything the
  # agent or the reviewer wrote is escaped; backslashes are doubled
  # because zenity unescapes \n etc. in --text.
  renderRequest = pkgs.writeText "nuketown-render-request.jq" ''
    def esc: gsub("\\\\"; "\\\\") | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
    def cut(n): if length > n then .[0:n] + "…" else . end;
    def bullets: map("\n  • " + (cut(300) | esc)) | join("");
    ($req[0]) as $r
    | (($rev[0]) // {status: "missing"}) as $v
    | (if $r.origin == "root"
       then "<b>\($r.requester | esc)</b> (via root) asks to run as <b>\($r.run_as.user | esc)</b>:\n\n"
       else "Agent <b>\($r.requester | esc)</b> wants to run as <b>\($r.run_as.user | esc)</b>:\n\n" end)
      + "<tt>\($r.display | cut(800) | esc)</tt>"
      + (if $r.kind != null then "\n\n<b>Kind:</b> \($r.kind.name | esc)" else "" end)
      + (if $r.why != "" then "\n\n<b>\(if $r.origin == "root" then "Stated" else "Agent's stated" end) reason:</b> <i>\($r.why | cut(400) | esc)</i>" else "" end)
      + (if ($r.snapshots | length) > 0
         then "\n\n<b>Files</b> (snapshotted; the snapshot is what runs): "
              + ([$r.snapshots[] | (.path | esc) + (if .executed then " (runs)" else "" end)] | join(", "))
         else "" end)
      + "\n\n"
      + (if $v.status == "ok" then
           "<b>Reviewer</b>: risk <b>\($v.risk | ascii_upcase)</b>, recommends <b>\($v.recommendation | ascii_upcase)</b>\n"
           + (if (($v.headline // "") | type) == "string" and ($v.headline // "") != ""
              then "<b>\($v.headline | cut(200) | esc)</b>\n" else "" end)
           + ($v.summary | cut(1500) | esc)
           + (if ($v.notes | length) > 0 then "\n<b>Concerns:</b>" + ($v.notes | bullets) else "" end)
           + (if ($v.not_shown | length) > 0 then "\n<b>Could not verify:</b>" + ($v.not_shown | bullets) else "" end)
         elif $v.status == "pending" then "<i>Reviewer is still reading this request; the dialog will update when it's done.</i>"
         elif $v.status == "disabled" then "<i>No reviewer configured.</i>"
         elif $v.status == "skipped" and $v.by == "collector" then "<b>No review:</b> \(($v.reason // "") | cut(300) | esc)"
         elif $v.status == "skipped" then "<i>Not reviewed: \(($v.reason // "skipped") | esc).</i>"
         else "<b>No review</b>: " + (($v.reason // $v.status) | esc)
         end)
  '';

  # Default prompter: the approval card (prompter/, GTK 4 on X11 or
  # Wayland). It keeps zenity's contract: exit 0 = approve; on deny the
  # first line of stdout is the reason (may be empty); "no answer within
  # Ns" on timeout; SIGTERM denies. Deny has the keyboard (Esc opens the
  # reason, Esc again denies; only a click or Ctrl+Enter approves), and the card
  # updates in place when review.json lands. NUKETOWN_PROMPT_NOTE (from
  # the broker) is shown on the card.
  cardPrompter = pkgs.callPackage ./prompter { };

  prompter = if cfg.prompter != null then cfg.prompter else lib.getExe cardPrompter;

  # Asks about a decrypt with no command (sops-unlock). Exit 0 = go ahead.
  decryptPrompter = pkgs.writeShellScript "nuketown-decrypt-prompter" ''
    set -uo pipefail
    SRC=$(printf '%s' "$1" | ${pkgs.gnused}/bin/sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    ZPID=""
    trap '[ -n "$ZPID" ] && kill "$ZPID" 2>/dev/null; exit 1' TERM INT
    ${pkgs.zenity}/bin/zenity --question --title="Nuketown: Decrypt" \
      --text="Decrypt with your GPG key:\n\n<tt>$SRC</tt>''${NUKETOWN_PROMPT_NOTE:+\n\n$NUKETOWN_PROMPT_NOTE}" \
      --ok-label="Unlock" --cancel-label="Deny" --default-cancel \
      --width=500 --timeout=120 2>/dev/null &
    ZPID=$!
    wait "$ZPID"
  '';

  # ── Multi-op Broker Handler ─────────────────────────────────
  # Reads all ops from a connection, then decides how to fulfill them.
  # Only the nuketown-approval service user can connect (socket group).
  #   REQUEST:<id>            a sudo request; details in ${runDir}/<id>
  #   DECRYPT:<src>:<dest>    decrypt with the human's GPG key (YubiKey)
  # Replies APPROVED / DECRYPTED, or DENIED[:<reason>] (one line).
  #
  # Decrypts never start gpg's PIN prompt while a dialog is up (it would
  # open behind the dialog and grab the keyboard): the dialog comes first
  # and gpg runs after Approve. With touchApproves, gpg is also tried in
  # parallel with --pinentry-mode error, so when the key is already
  # unlocked a YubiKey touch alone approves; if a PIN is needed that
  # attempt fails at once and the PIN is asked after Approve.
  brokerHandler = pkgs.writeShellScript "nuketown-broker-handler" ''
    set -uo pipefail
    export PATH=${lib.makeBinPath (with pkgs; [ coreutils gnupg zenity gnused ])}:$PATH

    deny() {   # deny [reason]
      local r
      r=$(printf '%s' "''${1-}" | tr -d '\000-\037' | head -c 500)
      if [ -n "$r" ]; then echo "DENIED:$r"; else echo "DENIED"; fi
      exit 0
    }

    # ── Read all ops from the connection ──────────────────────
    DECRYPT_SRC=""
    DECRYPT_DEST=""
    REQ_ID=""

    while IFS= read -r REQUEST && [ -n "$REQUEST" ]; do
      case "''${REQUEST%%:*}" in
        DECRYPT)
          DECRYPT_SRC=$(printf '%s' "$REQUEST" | cut -d: -f2)
          DECRYPT_DEST=$(printf '%s' "$REQUEST" | cut -d: -f3)
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

    if [ -n "$REQ_ID" ]; then
      ASK=(${prompter} "$REQ_DIR")
    elif [ -n "$DECRYPT_SRC" ]; then
      ASK=(${decryptPrompter} "$DECRYPT_SRC")
    else
      echo "ERROR: no valid operations"
      exit 0
    fi

    TMP=$(mktemp -d)
    PPID_=""; GPID=""
    cleanup() {
      [ -n "$PPID_" ] && kill "$PPID_" 2>/dev/null
      [ -n "$GPID" ] && kill "$GPID" 2>/dev/null
      rm -rf "$TMP"
    }
    trap cleanup EXIT

    finish_decrypt() {
      install -m 600 "$TMP/plain" "$DECRYPT_DEST" || deny "could not write $DECRYPT_DEST"
      if [ -n "$REQ_ID" ]; then echo "APPROVED"; else echo "DECRYPTED"; fi
      exit 0
    }

    # ── Ask (with an optional touch-only decrypt racing it) ──
    if [ -n "$DECRYPT_SRC" ]; then
      export NUKETOWN_PROMPT_NOTE="This also unlocks secrets with your GPG key. ${
        if cfg.touchApproves
        then "If the key is already unlocked, touching it approves; otherwise click Approve, then enter your PIN."
        else "Click Approve, then enter your PIN / touch the key."}"
    fi
    "''${ASK[@]}" < /dev/null > "$TMP/reason" 2>/dev/null &
    PPID_=$!
    ${lib.optionalString cfg.touchApproves ''
      if [ -n "$DECRYPT_SRC" ]; then
        gpg --batch --pinentry-mode error -d "$DECRYPT_SRC" > "$TMP/plain" 2>/dev/null &
        GPID=$!
      fi
    ''}
    while kill -0 "$PPID_" 2>/dev/null; do
      if [ -n "$GPID" ] && ! kill -0 "$GPID" 2>/dev/null; then
        if wait "$GPID"; then
          # Touched while the dialog was up: approve everything.
          GPID=""; kill "$PPID_" 2>/dev/null; wait "$PPID_" 2>/dev/null; PPID_=""
          finish_decrypt
        fi
        GPID=""   # needs a PIN (or no touch): ask after Approve
      fi
      sleep 0.1
    done
    wait "$PPID_"; RC=$?; PPID_=""
    if [ $RC -ne 0 ]; then
      deny "$(head -n1 "$TMP/reason" 2>/dev/null)"
    fi
    [ -z "$DECRYPT_SRC" ] && { echo "APPROVED"; exit 0; }

    # ── Approved; decrypt now (the dialog is gone, so a PIN prompt is visible)
    if [ -n "$GPID" ]; then
      # The touch-only attempt is still waiting for a touch.
      if wait "$GPID"; then GPID=""; finish_decrypt; fi
      GPID=""
    fi
    while true; do
      gpg -d "$DECRYPT_SRC" > "$TMP/plain" 2>/dev/null && finish_decrypt
      zenity --question --title="Nuketown: Retry" \
        --text="Decrypting with your GPG key failed (wrong PIN, no touch, or no key).\n\nRetry?" \
        --ok-label="Retry" --cancel-label="Deny" --default-cancel --width=400 2>/dev/null \
        || deny "decrypt failed"
    done
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

    renderer = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      default = renderRequest;
      description = ''
        jq program that renders a request as Pango markup
        (`jq -rn --slurpfile req request.json --slurpfile rev review.json
        -f <renderer>`), for custom (e.g. zenity) prompters and tests.
      '';
    };

    cardPrompter = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = cardPrompter;
      description = ''
        The built-in approval card (nuketown-prompter, GTK 4), the
        prompter used when `prompter` is null. For wrappers and tests;
        with NUKETOWN_PROMPTER_STATE=<file> it writes what it shows to
        that file as JSON after every change.
      '';
    };

    prompter = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Command that asks the human about a sudo request. It gets the
        request directory (request.json, review.json, snapshots/) as its
        only argument and exits 0 to approve, anything else to deny.
        null uses the built-in approval card (`cardPrompter`).

        On deny, the first line of stdout is the reason shown to the
        requester. review.json may be {"status":"pending"} when the
        prompter starts and is replaced (atomically) when the review
        lands; re-read it to update. The broker may send SIGTERM (a
        YubiKey touch approved a decrypt, see touchApproves). For a
        decrypt, NUKETOWN_PROMPT_NOTE carries a line to show. gpg's PIN
        prompt only appears after the prompter has exited 0.
      '';
    };

    touchApproves = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        For requests that also decrypt (sudoex --decrypt, sops-unlock),
        try the decrypt alongside the dialog without a PIN prompt
        (gpg --pinentry-mode error), so that when the key is already
        unlocked a YubiKey touch alone approves. Only safe when the key
        requires a touch to decrypt: with a software key or a cached
        passphrase that parallel decrypt succeeds with no human action
        and approves the request by itself. Set false for those.
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
