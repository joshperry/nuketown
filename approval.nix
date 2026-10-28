# Sudo approval: the nuketown-approval service user.
#
# Agents have no sudo rule that reaches root. Their `sudo` shim and
# `sudoex` run `sudo -u nuketown-approval nuketown-approve ... -- argv`.
# nuketown-approve runs as the unprivileged service user and:
#
#   1. writes /run/nuketown-approval/<id>/request.json (argv as JSON)
#   2. snapshots the script that will run (read *as the requester*, so it
#      can't read anything the requester can't) and rewrites argv to run
#      the snapshot: what runs is what was reviewed and shown
#   3. optionally asks the reviewer agent for a plain-English analysis
#   4. asks the human's broker (REQUEST:<id>), which renders the dialog
#   5. on approval, runs the command through sudo, passing stdio and the
#      exit code through, and writes an audit record
#
# Every privileged step the service user takes is a sudo call, so it is
# logged by sudo. Root itself only runs the approved command.

{ config, lib, pkgs, ... }:

let
  cfg = config.nuketown;
  acfg = cfg.approval;

  enabledAgents = lib.filterAttrs (_: a: a.enable) cfg.agents;
  sudoAgents = lib.filterAttrs (_: a: a.sudo.enable) enabledAgents;
  active = cfg.enable && sudoAgents != {} && cfg.humanUser != null;

  user = "nuketown-approval";
  readGroup = "nuketown-approval-read";
  runDir = "/run/nuketown-approval";
  socketPath = "/run/nuketown-broker/socket";
  mockFile = "/run/nuketown-broker/mode";

  reviewerEnabled = acfg.reviewer.enable;

  # Effective allow list per agent: approvalAllow, else the legacy
  # sudo.commands list, else null (any command).
  allowList = agent:
    if agent.sudo.approvalAllow != null then agent.sudo.approvalAllow
    else if agent.sudo.commands != [] then agent.sudo.commands
    else null;

  # Runs as the requester (via sudo -u) to read a file for a snapshot.
  # Exit: 0 ok, 5 missing, 3 not a regular file, 2 unreadable, 4 too large.
  readHelper = pkgs.writeShellScript "nuketown-approval-read" ''
    p=$1
    [ -e "$p" ] || exit 5
    [ -f "$p" ] || exit 3
    [ -r "$p" ] || exit 2
    size=$(${pkgs.coreutils}/bin/stat -L -c %s -- "$p") || exit 2
    [ "$size" -le ${toString acfg.snapshotMaxBytes} ] || exit 4
    exec ${pkgs.coreutils}/bin/cat -- "$p"
  '';

  # Runs the approved command in the requester's directory (or / if the
  # run-as user can't enter it, which is where sudo would leave it unable
  # to resolve relative paths anyway), with the system PATH.
  runIn = pkgs.writeShellScript "nuketown-run-in" ''
    cd -- "$1" 2>/dev/null || cd /
    shift
    export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin
    exec "$@"
  '';

  reviewPrompt = pkgs.writeText "nuketown-review-prompt.md" ''
    You are the adversarial reviewer for a sudo request on a NixOS machine.
    An AI agent wants to run a command as root (or as another user). A
    human will approve or deny it based on what you write. Assume the
    agent may be mistaken or compromised; your job is to tell the human,
    in plain English, what will actually happen.

    The request directory is given below: request.json (argv as JSON,
    the agent's stated reason in "why", run-as user) and snapshots/ with
    the exact contents of any scripts that will run. The snapshot is what
    executes, not the original path.

    Do:
    - Describe concretely what the command and every script will do, step
      by step, as the human would want to know it.
    - Flag anything beyond what the stated "why" needs, anything that
      persists (users, keys, services, cron, sudoers, ssh, PATH, shell
      rc files), anything that sends data off the machine, and anything
      destructive.
    - List what you cannot see: files the script sources or reads at run
      time, downloads, commands whose behaviour depends on state you can't
      inspect. Scripts that locate siblings via $0/dirname will look in
      the snapshot directory, not the original.

    Reply with ONLY a JSON object, no prose and no code fences:
    {"summary": "<2-5 plain sentences>",
     "risk": "low" | "medium" | "high",
     "recommendation": "approve" | "deny" | "ask",
     "notes": ["<specific concern>", ...],
     "not_shown": ["<thing you could not verify>", ...]}
  '';

  # Default reviewer command: runs as the reviewer agent, prints JSON.
  defaultReviewCommand = pkgs.writeShellScript "nuketown-review" ''
    set -uo pipefail
    dir=$1
    export PATH="/etc/profiles/per-user/$(${pkgs.coreutils}/bin/id -un)/bin:/run/current-system/sw/bin:$PATH"
    {
      ${pkgs.coreutils}/bin/cat ${reviewPrompt}
      printf '\n## request.json\n\n'
      ${pkgs.coreutils}/bin/cat "$dir/request.json"
      for f in "$dir"/snapshots/*/*; do
        [ -f "$f" ] || continue
        printf '\n## snapshot %s\n\n' "''${f#"$dir"/}"
        ${pkgs.coreutils}/bin/head -c 200000 "$f"
      done
    } > "''${TMPDIR:-/tmp}/nuketown-review-$$.md"
    out=$(claude -p --output-format text < "''${TMPDIR:-/tmp}/nuketown-review-$$.md")
    rc=$?
    ${pkgs.coreutils}/bin/rm -f "''${TMPDIR:-/tmp}/nuketown-review-$$.md"
    [ $rc -eq 0 ] || exit $rc
    # Tolerate code fences or prose around the object.
    printf '%s' "$out" | ${pkgs.gnused}/bin/sed -n '/^[[:space:]]*{/,/}[[:space:]]*$/p'
  '';

  reviewCommand =
    if acfg.reviewer.command != null then acfg.reviewer.command else "${defaultReviewCommand}";

  agentCase = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: agent:
    let l = allowList agent; in
    "      ${lib.escapeShellArg name}) ALLOW=(${
      if l == null then "" else lib.concatMapStringsSep " " lib.escapeShellArg l
    }); ALLOW_ANY=${if l == null then "1" else "0"} ;;"
  ) sudoAgents);

  approve = pkgs.writeShellScriptBin "nuketown-approve" ''
    set -uo pipefail
    export PATH=${lib.makeBinPath (with pkgs; [ coreutils jq socat gnused findutils systemd ])}
    SUDO=/run/wrappers/bin/sudo
    SYSPATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin

    die() { echo "nuketown-approve: $*" >&2; exit 1; }

    quote_argv() {
      local out
      printf -v out '%q ' "$@"
      printf '%s' "''${out% }"
    }

    json_array() {
      local a out="["
      local sep=""
      for a in "$@"; do
        out+="$sep$(printf '%s' "$a" | jq -Rs .)"
        sep=","
      done
      printf '%s]' "$out"
    }

    [ "$(id -un)" = ${user} ] || die "must run as ${user} (via sudo -u ${user})"
    REQUESTER=''${SUDO_USER-}
    case "$REQUESTER" in
${agentCase}
      *) die "requester '$REQUESTER' is not a sudo-enabled nuketown agent" ;;
    esac
    cd /

    # ── Arguments ────────────────────────────────────────────────
    DECRYPTS=() WHY="" CWD="/" RUN_USER="" RUN_GROUP=""
    LOGIN=0 SHELLMODE=0 SETHOME=0 DECRYPT_ONLY=0
    while [ $# -gt 0 ]; do
      case $1 in
        --decrypt)
          # The broker protocol is line- and colon-delimited.
          if [[ "''${2-}" != *:* || "$2" == *$'\n'* || "$2" == *$'\r'* ]]; then
            die "--decrypt takes src:dest"
          fi
          DECRYPTS+=("$2"); shift 2 ;;
        --why) WHY=''${2-}; shift 2 ;;
        --cwd) CWD=''${2-}; shift 2 ;;
        --user) RUN_USER=''${2-}; shift 2 ;;
        --group) RUN_GROUP=''${2-}; shift 2 ;;
        --login) LOGIN=1; shift ;;
        --shell) SHELLMODE=1; shift ;;
        --set-home) SETHOME=1; shift ;;
        --decrypt-only) DECRYPT_ONLY=1; shift ;;
        --) shift; break ;;
        *) die "unknown option: $1" ;;
      esac
    done
    ARGV=("$@")

    [[ "$CWD" == /* && "$CWD" != *$'\n'* ]] || die "--cwd must be an absolute path"
    for v in "$RUN_USER" "$RUN_GROUP"; do
      [[ -z "$v" || "$v" =~ ^#?[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || die "bad user/group: $v"
    done
    if [ "$DECRYPT_ONLY" = 1 ]; then
      [ ''${#DECRYPTS[@]} -gt 0 ] && [ ''${#ARGV[@]} -eq 0 ] || die "--decrypt-only takes --decrypt and no command"
    elif [ ''${#ARGV[@]} -eq 0 ] && [ "$LOGIN$SHELLMODE" = 00 ]; then
      die "no command"
    fi

    ID="$(date -u +%Y%m%dT%H%M%SZ)-$REQUESTER-$$-$RANDOM"
    DIR=${runDir}/$ID
    # setgid parent: everything here is group ${readGroup} (human, reviewer)
    mkdir -m 2751 "$DIR" "$DIR/snapshots" || die "cannot create $DIR"
    chmod 0755 "$DIR/snapshots"
    DECISION="error" PROMPTER="none" RC=1 EXEC_ARGV=() SNAPS="[]"

    finish() {
      local review='{}'
      [ -f "$DIR/review.json" ] && review=$(cat "$DIR/review.json")
      local rec
      rec=$(jq -cn --arg id "$ID" --arg requester "$REQUESTER" \
        --argjson argv "$(json_array "''${ARGV[@]}")" \
        --argjson exec_argv "$(json_array "''${EXEC_ARGV[@]}")" \
        --argjson snapshots "$SNAPS" --argjson review "$review" \
        --arg decision "$DECISION" --arg prompter "$PROMPTER" --argjson exit "$RC" \
        '{id:$id, requester:$requester, argv:$argv, exec_argv:$exec_argv,
          snapshots:[$snapshots[] | {path, sha256}],
          review:{status:$review.status, risk:$review.risk, recommendation:$review.recommendation},
          decision:$decision, prompter:$prompter, exit:$exit}')
      printf '%s\n' "$rec" | systemd-cat -t nuketown-approval || true
      printf '%s\n' "$rec" > "$DIR/decision.json" 2>/dev/null || true
      ${lib.optionalString (acfg.audit.dir != null) ''
        cp -r "$DIR" ${lib.escapeShellArg acfg.audit.dir}/ 2>/dev/null || true
      ''}
      rm -rf "$DIR"
    }
    trap 'finish' EXIT

    # ── Resolve argv[0] and snapshot ─────────────────────────────
    is_system() {
      local rp
      case "$1" in /run/wrappers/*|/nix/store/*) return 0 ;; esac
      rp=$(realpath -e -- "$1" 2>/dev/null) || return 1
      [[ "$rp" == /nix/store/* ]]
    }

    # Absolute, lexically normalised (no file system access).
    abspath() {
      if [[ "$1" == /* ]]; then realpath -ms -- "$1"
      else realpath -ms -- "''${CWD%/}/$1"; fi
    }

    resolve() {
      local c=$1 d
      if [[ "$c" == */* ]]; then abspath "$c"
      else
        for d in ''${SYSPATH//:/ }; do
          [ -x "$d/$c" ] && { printf '%s' "$d/$c"; return 0; }
        done
        return 1
      fi
    }

    NSNAP=0 SNAP_OUT=""
    # snapshot <path> <executable 0|1> <required 0|1>; sets SNAP_OUT.
    # Not called in a subshell: it updates NSNAP/SNAPS and may die.
    snapshot() {
      local path=$1 exe=$2 req=$3 base dst rc sha
      NSNAP=$((NSNAP + 1))
      base=$(basename -- "$path")
      mkdir -m 0755 "$DIR/snapshots/$NSNAP"
      dst="$DIR/snapshots/$NSNAP/$base"
      "$SUDO" -u "$REQUESTER" -- ${readHelper} "$path" > "$dst" < /dev/null
      rc=$?
      if [ $rc -ne 0 ]; then
        rm -rf "$DIR/snapshots/$NSNAP"
        if [ "$req" = 1 ] || [ $rc -eq 2 ] || [ $rc -eq 4 ]; then
          case $rc in
            5) die "$path does not exist (or $REQUESTER cannot see it)" ;;
            3) die "$path is not a regular file" ;;
            2) die "$REQUESTER cannot read $path" ;;
            4) die "$path is larger than ${toString acfg.snapshotMaxBytes} bytes" ;;
            *) die "could not snapshot $path" ;;
          esac
        fi
        return 1
      fi
      chmod "$([ "$exe" = 1 ] && echo 0755 || echo 0644)" "$dst"
      sha=$(sha256sum < "$dst" | cut -d' ' -f1)
      SNAPS=$(jq -c --arg p "$path" --arg s "''${dst#"$DIR"/}" --arg h "$sha" --argjson e "$([ "$exe" = 1 ] && echo true || echo false)" \
        '. + [{path:$p, snapshot:$s, sha256:$h, executed:$e}]' <<< "$SNAPS")
      SNAP_OUT=$dst
    }

    EXEC_ARGV=("''${ARGV[@]}")
    if [ ''${#ARGV[@]} -gt 0 ]; then
      ARG0=$(resolve "''${ARGV[0]}") || die "''${ARGV[0]}: not found in $SYSPATH (use an absolute path)"
      [[ "$ARG0" != *=* ]] || die "command path may not contain '='"
      EXEC_ARGV[0]=$ARG0

      # Allow list (checked against the resolved command)
      if [ "$ALLOW_ANY" != 1 ]; then
        ok=0
        for a in "''${ALLOW[@]}"; do
          # Compare resolved paths, not realpaths: coreutils is one
          # binary behind symlinks, so realpath(id) == realpath(true).
          ra=$(resolve "$a" 2>/dev/null) || ra=$a
          if [ "$ra" = "$ARG0" ]; then
            ok=1; break
          fi
        done
        [ $ok = 1 ] || die "$REQUESTER may not request $ARG0 (not in sudo.approvalAllow)"
      fi

      SNAPPED=()
      if ! is_system "$ARG0"; then
        snapshot "$ARG0" 1 1 || exit 1
        EXEC_ARGV[0]=$SNAP_OUT
        SNAPPED+=(0)
      fi

      # Interpreter: snapshot and run the script argument too.
      rp0=$(realpath -e -- "$ARG0" 2>/dev/null || printf '%s' "$ARG0")
      case "$(basename -- "$rp0")" in
        bash|sh|dash|zsh|ksh|fish|python|python3|python3.*|perl|node|ruby|lua|lua5.*)
          i=1
          while [ $i -lt ''${#ARGV[@]} ]; do
            a=''${ARGV[$i]}
            case "$a" in
              -c|-e|-m|-E|--eval|--command|-) i=-1; break ;;   # inline code / stdin / module
              -o|-O|-W|-X|-I|-r|--rcfile|--init-file) i=$((i + 2)) ;;
              --) i=$((i + 1)); break ;;
              -*) i=$((i + 1)) ;;
              *) break ;;
            esac
          done
          if [ $i -ge 1 ] && [ $i -lt ''${#ARGV[@]} ]; then
            a=$(abspath "''${ARGV[$i]}")
            # Required: an unsnapshotted script would run unseen as root.
            if ! is_system "$a"; then
              snapshot "$a" 1 1 || exit 1
              EXEC_ARGV[$i]=$SNAP_OUT
              SNAPPED+=("$i")
            fi
          fi
          ;;
      esac

      # Other path-like arguments: snapshot for review only (max 8).
      n=0
      for ((i = 1; i < ''${#ARGV[@]} && n < 8; i++)); do
        [[ " ''${SNAPPED[*]} " == *" $i "* ]] && continue
        a=''${ARGV[$i]}
        [[ "$a" == */* && "$a" != -* ]] || continue
        a=$(abspath "$a")
        is_system "$a" && continue
        snapshot "$a" 0 0 && n=$((n + 1))
      done
    fi

    DISPLAY_CMD=$(quote_argv "''${ARGV[@]}")
    jq -n --arg id "$ID" --arg requester "$REQUESTER" --arg time "$(date -u +%FT%TZ)" \
      --arg cwd "$CWD" --arg why "$WHY" --arg user "$RUN_USER" --arg group "$RUN_GROUP" \
      --argjson login "$LOGIN" --argjson shell "$SHELLMODE" --argjson set_home "$SETHOME" \
      --arg display "$DISPLAY_CMD" \
      --argjson argv "$(json_array "''${ARGV[@]}")" \
      --argjson exec_argv "$(json_array "''${EXEC_ARGV[@]}")" \
      --argjson decrypt "$(json_array "''${DECRYPTS[@]}")" \
      --argjson snapshots "$SNAPS" \
      '{id:$id, requester:$requester, time:$time, cwd:$cwd, why:$why,
        run_as:{user:(if $user == "" then "root" else $user end), group:$group,
                login:($login == 1), shell:($shell == 1), set_home:($set_home == 1)},
        argv:$argv, exec_argv:$exec_argv, display:$display, decrypt:$decrypt,
        snapshots:$snapshots}' > "$DIR/request.json"
    chmod 0640 "$DIR/request.json"

    # ── Review ───────────────────────────────────────────────────
    write_review() { jq -n "$@" > "$DIR/review.json"; chmod 0640 "$DIR/review.json"; }
    if [ ${if reviewerEnabled then "1" else "0"} = 1 ] && [ "$DECRYPT_ONLY" = 0 ]; then
      out=$(timeout --kill-after=5 ${toString acfg.reviewer.timeout} \
              "$SUDO" -H -u ${lib.escapeShellArg (toString acfg.reviewer.agent)} -- ${reviewCommand} "$DIR" \
              < /dev/null 2> "$DIR/review.stderr" | head -c 65536)
      rc=''${PIPESTATUS[0]}
      if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
        write_review --arg r "reviewer timed out after ${toString acfg.reviewer.timeout}s" '{status:"unavailable", reason:$r}'
      elif [ "$rc" != 0 ]; then
        write_review --arg r "reviewer failed (exit $rc)" '{status:"unavailable", reason:$r}'
      elif printf '%s' "$out" | jq -e '
             (.summary | type == "string") and
             (.risk | IN("low", "medium", "high")) and
             (.recommendation | IN("approve", "deny", "ask")) and
             ((.notes // []) | type == "array") and
             ((.not_shown // []) | type == "array")' > /dev/null 2>&1; then
        printf '%s' "$out" | jq '{status:"ok", summary:.summary[0:2000], risk, recommendation,
          notes:((.notes // []) | map(tostring | .[0:500]) | .[0:20]),
          not_shown:((.not_shown // []) | map(tostring | .[0:500]) | .[0:20])}' > "$DIR/review.json"
        chmod 0640 "$DIR/review.json"
      else
        write_review '{status:"unavailable", reason:"reviewer output was not valid review JSON"}'
      fi
    else
      write_review '{status:"disabled"}'
    fi

    # ── Ask the human ────────────────────────────────────────────
    REQS=""
    for d in "''${DECRYPTS[@]}"; do REQS+="DECRYPT:$d"$'\n'; done
    if [ -f ${mockFile} ]; then
      PROMPTER=mock
      mode=$(tr -d '\n\r ' < ${mockFile})
      case "$mode" in
        MOCK_APPROVED) echo "[MOCK] Auto-approved: $DISPLAY_CMD" >&2; RESPONSE=APPROVED ;;
        MOCK_DENIED) echo "[MOCK] Auto-denied: $DISPLAY_CMD" >&2; RESPONSE=DENIED ;;
        *) die "invalid mock mode in ${mockFile} (got: '$mode'; expected MOCK_APPROVED or MOCK_DENIED)" ;;
      esac
    else
      PROMPTER=broker
      [ -S ${socketPath} ] || die "approval broker is not running (no socket at ${socketPath})"
      if [ "$DECRYPT_ONLY" = 1 ]; then
        RESPONSE=$(printf '%s\n' "$REQS" | socat STDIO,ignoreeof UNIX-CONNECT:${socketPath} || echo ERROR)
      else
        RESPONSE=$(printf '%sREQUEST:%s\n\n' "$REQS" "$ID" | socat STDIO,ignoreeof UNIX-CONNECT:${socketPath} || echo ERROR)
      fi
    fi

    case "$RESPONSE" in
      APPROVED|DECRYPTED) DECISION=approved ;;
      DENIED) DECISION=denied; echo "Request denied." >&2; RC=1; exit 1 ;;
      *) DECISION=error; echo "Error communicating with approval broker (got: '$RESPONSE')" >&2; RC=1; exit 1 ;;
    esac

    if [ "$DECRYPT_ONLY" = 1 ]; then
      RC=0; exit 0
    fi

    # ── Run ──────────────────────────────────────────────────────
    SUDO_ARGS=()
    [ -n "$RUN_USER" ] && SUDO_ARGS+=(-u "$RUN_USER")
    [ -n "$RUN_GROUP" ] && SUDO_ARGS+=(-g "$RUN_GROUP")
    [ "$SETHOME" = 1 ] && SUDO_ARGS+=(-H)
    [ "$LOGIN" = 1 ] && SUDO_ARGS+=(-i)
    [ "$SHELLMODE" = 1 ] && SUDO_ARGS+=(-s)
    if [ "$LOGIN$SHELLMODE" != 00 ]; then
      CMD=("''${EXEC_ARGV[@]}")
    else
      CMD=(${runIn} "$CWD" "''${EXEC_ARGV[@]}")
    fi
    # Handlers (not ignore) so the command still gets default signal
    # dispositions, and we survive ^C to write the audit record.
    trap ':' INT QUIT TERM
    PATH=$SYSPATH "$SUDO" "''${SUDO_ARGS[@]}" -- "''${CMD[@]}"
    RC=$?
    exit $RC
  '';
in
{
  options.nuketown.approval = {
    reviewer = {
      enable = lib.mkEnableOption ''
        a reviewer agent that writes a plain-English, adversarial analysis
        of every sudo request before the human is asked
      '';
      agent = lib.mkOption {
        type = lib.types.str;
        default = "reviewer";
        description = "Unix user (normally a nuketown agent) that runs the review command.";
      };
      command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Review command, run as the reviewer with the request directory as
          its only argument. It must print one JSON object:
          {summary, risk: low|medium|high, recommendation: approve|deny|ask,
          notes: [..], not_shown: [..]}. null uses a built-in `claude -p`
          command with a fixed adversarial prompt.
        '';
      };
      timeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 45;
        description = "Seconds to wait for the review; after that the human is asked with \"review unavailable\".";
      };
    };

    audit = {
      dir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "/var/lib/nuketown-approval";
        description = "Where each finished request directory is kept (persisted). null keeps only the journal record.";
      };
      keepDays = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = 30;
        description = "Delete audit records older than this many days. null keeps them forever.";
      };
    };

    snapshotMaxBytes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1048576;
      description = "Largest file nuketown-approve will snapshot.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "The nuketown-approve command (for tests and wrappers).";
    };
  };

  config = lib.mkIf active {
    nuketown.approval.package = approve;

    assertions = [{
      assertion = !reviewerEnabled || config.users.users ? ${acfg.reviewer.agent};
      message = "nuketown.approval.reviewer.agent (${acfg.reviewer.agent}) must be a user on this machine (normally a nuketown agent).";
    }];

    environment.systemPackages = [ approve ];

    users.users.${user} = {
      isSystemUser = true;
      group = user;
      extraGroups = [ "nuketown-broker" ];
      home = "/var/empty";
      shell = pkgs.shadow + "/bin/nologin";
    };
    users.groups.${user} = {};
    users.groups.${readGroup}.members =
      [ cfg.humanUser ] ++ lib.optional reviewerEnabled acfg.reviewer.agent;

    security.sudo.extraRules = [
      # Agents may only start nuketown-approve as the service user.
      {
        users = lib.attrNames sudoAgents;
        runAs = user;
        commands = [{ command = "/run/current-system/sw/bin/nuketown-approve"; options = [ "NOPASSWD" ]; }];
      }
      # The service user is root-equivalent by design: it runs whatever the
      # human approves. The point is that every step it takes (snapshot
      # reads as the requester, the review, the approved command) is a
      # logged sudo call, and root never parses requests or reviews.
      {
        users = [ user ];
        runAs = "ALL:ALL";
        commands = [{ command = "ALL"; options = [ "NOPASSWD" ]; }];
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${runDir} 2751 ${user} ${readGroup} -"
    ] ++ lib.optional (acfg.audit.dir != null)
      "d ${acfg.audit.dir} 2750 ${user} ${readGroup} -";

    environment.persistence."/persist".directories = lib.mkIf (acfg.audit.dir != null) [
      { directory = acfg.audit.dir; user = user; group = readGroup; mode = "2750"; }
    ];

    systemd.services.nuketown-approval-prune = lib.mkIf (acfg.audit.dir != null && acfg.audit.keepDays != null) {
      description = "Prune old nuketown approval audit records";
      serviceConfig = {
        Type = "oneshot";
        User = user;
        ExecStart = "${pkgs.findutils}/bin/find ${acfg.audit.dir} -mindepth 1 -maxdepth 1 -mtime +${toString acfg.audit.keepDays} -exec ${pkgs.coreutils}/bin/rm -rf {} +";
      };
    };
    systemd.timers.nuketown-approval-prune = lib.mkIf (acfg.audit.dir != null && acfg.audit.keepDays != null) {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = "daily"; Persistent = true; };
    };
  };
}
