# VM test: the built-in approval card (prompter/), driven like a human.
#
# machine: X11 + i3 (Josh's setup), the real broker and nuketown-approve,
# the stub reviewer, and the card behind a wrapper that records each card
# (approval-node.nix, card = true). xdotool clicks and types; the card's
# test hook (NUKETOWN_PROMPTER_STATE) says what it shows.
# wl: the same card under cage (Wayland, no XWayland) on a fixture
# request, keys from QEMU's keyboard.
#
# Screenshots land in the result: card-pending, card-reviewed,
# card-details, card-deny-reason, card-wayland.
#
#   nix build .#checks.x86_64-linux.vm-approval-card

{ pkgs, nuketownModule, home-manager, impermanence, sops-nix, nixpkgs-unstable }:

let
  # The "quick" kind's prompt timeout; everything else gets 120 s.
  timeout = 8;
  quickCmd = pkgs.writeShellScriptBin "quick-cmd" "echo quick";
  common = "${pkgs.path}/nixos/tests/common";

  i3Config = pkgs.writeText "i3-config" ''
    font pango:DejaVu Sans 10
    focus_follows_mouse no
  '';

  fixture = {
    "card-fixture/request.json".text = builtins.toJSON {
      id = "fixture"; requester = "ada"; origin = "agent"; run_as.user = "root"; cwd = "/agents/ada";
      argv = [ "systemctl" "restart" "iwd" ]; display = "systemctl restart iwd";
      why = "wifi dropped <b>again</b>"; kind = null; snapshots = [ ]; decrypt = [ ]; prompt_timeout = 0;
    };
    "card-fixture/review.json".text = builtins.toJSON {
      status = "ok"; headline = "Restarts the wifi daemon; connections drop briefly.";
      summary = "Restarts iwd, so wifi disconnects for a few seconds."; risk = "medium"; recommendation = "approve";
      notes = [ "Any download or ssh session over wifi is interrupted." ]; not_shown = [ ];
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "nuketown-approval-card";
  node.pkgsReadOnly = false;

  nodes.machine = { pkgs, lib, ... }: {
    imports = [
      (import ./approval-node.nix {
        inherit nuketownModule home-manager impermanence sops-nix nixpkgs-unstable;
        card = true;
      })
      "${common}/x11.nix"
    ];
    test-support.displayManager.auto.user = "human";
    services.displayManager.defaultSession = "none+i3";
    services.xserver.windowManager.i3 = { enable = true; configFile = i3Config; };
    fonts.packages = [ pkgs.dejavu_fonts ];
    environment.systemPackages = [ pkgs.xdotool pkgs.xclip pkgs.i3 quickCmd ];
    nuketown.approval.kinds.quick = { command = "/run/current-system/sw/bin/quick-cmd"; inherit timeout; };
    virtualisation.memorySize = 2048;
  };

  nodes.wl = { pkgs, lib, ... }: {
    imports = [ "${common}/wayland-cage.nix" ];
    fonts.packages = [ pkgs.dejavu_fonts ];
    environment.systemPackages = [ pkgs.jq ];
    environment.etc = fixture;
    services.cage.program = pkgs.writeShellScript "card-under-cage" ''
      unset DISPLAY
      NUKETOWN_PROMPTER_STATE=/tmp/wl-state.json \
        ${pkgs.lib.getExe (pkgs.callPackage ../prompter { })} /etc/card-fixture > /tmp/wl-stdout
      echo $? > /tmp/wl-rc
      exec ${pkgs.coreutils}/bin/sleep infinity
    '';
    virtualisation.memorySize = 1536;
  };

  testScript = builtins.readFile ./approval-lib.py + ''
    import time

    def x(cmd):
        return machine.succeed(f"su - human -c 'DISPLAY=:0 {cmd}'")

    def card_count():
        return int(machine.succeed("ls /tmp/cards | wc -l").strip())

    def state(n):
        return json.loads(machine.succeed(f"cat /tmp/cards/{n}/state.json"))

    def wait_card(n0, armed=True):
        """The next card is up, laid out, and (armed) takes keys and Approve clicks."""
        n = n0 + 1
        machine.wait_until_succeeds(
            f"jq -e '.bounds.deny and .size[0] > 0 and .xid' /tmp/cards/{n}/state.json", timeout=60)
        if armed:
            machine.wait_until_succeeds(f"jq -e .armed /tmp/cards/{n}/state.json", timeout=10)
            machine.sleep(0.3)    # i3 has placed it
        return n

    def wait_state(n, jq, timeout=30):
        machine.wait_until_succeeds(f"jq -e '{jq}' /tmp/cards/{n}/state.json", timeout=timeout)
        return state(n)

    def click(n, name, extra="click 1"):
        s = state(n)
        bx, by, bw, bh = s["bounds"][name]
        x(f"xdotool mousemove --window {s['xid']} {bx + bw // 2} {by + bh // 2} {extra}")

    def i3_card():
        def find(node):
            if node.get("name") == "Nuketown: Sudo Approval":
                return node
            for c in node.get("nodes", []) + node.get("floating_nodes", []):
                f = find(c)
                if f:
                    return f
        return find(json.loads(x("i3-msg -t get_tree")))

    def card_result(n, cause=None):
        machine.wait_until_succeeds(f"test -s /tmp/cards/{n}/rc", timeout=60)
        res = int(machine.succeed(f"cat /tmp/cards/{n}/rc")), machine.succeed(f"cat /tmp/cards/{n}/stdout")
        if cause is not None:
            got = state(n)
            assert got["final"] and got["cause"] == cause, (cause, res, got)
        return res

    start_all()
    setup()
    machine.wait_for_x()
    machine.succeed("mkdir -p /tmp/cards && chmod 1777 /tmp/cards")
    machine.wait_until_succeeds("su - human -c 'DISPLAY=:0 i3-msg -t get_version'", timeout=60)
    machine.succeed(as_ada("printf '#!/bin/sh\\nfor d in $(ls -td /var/lib/nuketown-approval/*/ | head -2); do\\n  ls \"$d\"\\n  cat \"$d/review.json\"\\ndone\\n' > ~/check.sh"))

    with subtest("fresh card: the keyboard is on Deny; Enter and Esc never approve; Esc Esc denies"):
        machine.succeed("echo ok > /tmp/reviewer-mode")
        n0 = card_count()
        start_bg("ada", "sudo --why 'check the clock' date")
        n = n0 + 1
        # Typing that was meant for another window doesn't reach the card
        # in its first second (no reason field, no decision): the keys go
        # out within ~0.1 s of the card's first state dump.
        x(f"sh -c \"until jq -e .bounds.deny /tmp/cards/{n}/state.json >/dev/null 2>&1; do sleep 0.05; done; xdotool key space x ctrl+Return Escape Return\"")
        s = wait_state(n, '.armed and .dropped_keys >= 1')
        assert not s["deny_open"] and s["result"] is None and s["reason_text"] == "", s
        s = wait_state(n, '.review.state == "ok" and .focus == "deny"')
        assert s["title"] == "Nuketown: Sudo Approval", s["title"]
        assert s["backend"] == "GdkX11Display", s["backend"]
        assert s["texts"]["who"] == "ada wants to run as root", s["texts"]
        assert s["texts"]["command"] == "date", s["texts"]
        assert s["texts"]["remaining"] in ("Denies in 2:00", "Denies in 1:59", "Denies in 1:58"), s["texts"]["remaining"]
        # i3 floats it, as it did zenity's dialog.
        win = i3_card()
        assert win and win["floating"] in ("auto_on", "user_on"), win
        assert win["window_properties"]["class"] == "nuketown-prompter", win
        assert s["tooltips"] == {"deny": "Deny (Esc)", "approve": "Approve (Ctrl+Enter)", "info": "Details (Ctrl+I)"}, s["tooltips"]
        x("xdotool key Return")
        wait_state(n, '.deny_open and .focus == "reason" and .result == null')
        x("xdotool key Escape")
        rc, out = card_result(n, "reason-escape")
        assert rc == 1 and out == "", (rc, out)
        rc, out = wait_bg()
        assert rc == 1 and "Request denied." in out and "Reason:" not in out, (rc, out)

    with subtest("deny with a reason, inside the card"):
        n0 = card_count()
        start_bg("ada", "sudo --why 'tidy up' rm -rf /var/tmp/scratch")
        n = wait_card(n0)
        wait_state(n, '.review.state == "ok" and .focus == "deny"')
        x("xdotool key Escape")      # Esc on the card opens the reason
        wait_state(n, '.deny_open and .focus == "reason" and .result == null')
        x('xdotool type --delay 20 "too risky today"')
        wait_state(n, '.reason_text == "too risky today"')
        machine.screenshot("card-deny-reason")
        x("xdotool key Return")
        rc, out = card_result(n, "reason-enter")
        assert rc == 1 and out == "too risky today\n", (rc, out)
        rc, out = wait_bg()
        assert rc == 1 and "Reason: too risky today" in out, (rc, out)
        rec = [r for r in journal_records() if r["argv"] == ["rm", "-rf", "/var/tmp/scratch"]][-1]
        assert rec["decision"] == "denied" and rec["reason"] == "too risky today", rec

    with subtest("the Deny button sends what is typed; a long reason is cut to 500 bytes"):
        n0 = card_count()
        start_bg("ada", "sudo true")
        n = wait_card(n0)
        click(n, "deny")
        wait_state(n, '.deny_open and .focus == "reason"')
        x("xdotool type --delay 1 " + "x" * 520)
        wait_state(n, '(.reason_text | length) == 500', timeout=60)
        click(n, "deny")
        rc, out = card_result(n, "deny-button")
        assert rc == 1 and out == "x" * 500 + "\n", (rc, len(out))

    with subtest("approve with a click"):
        n0 = card_count()
        start_bg("ada", "sudo id -un")
        n = wait_card(n0)
        click(n, "approve")
        rc, out = card_result(n, "approve")
        assert rc == 0 and out == "", (rc, out)
        rc, out = wait_bg()
        assert rc == 0 and out.strip() == "root", (rc, out)

    with subtest("keys: Ctrl+I toggles details; Tab and Space never reach Approve; Ctrl+Enter approves"):
        n0 = card_count()
        start_bg("ada", "sudo id -un")
        n = wait_card(n0)
        x("xdotool key ctrl+i")
        wait_state(n, '.details_open')
        x("xdotool key ctrl+i")
        wait_state(n, '.details_open | not')
        for _ in range(8):
            x("xdotool key Tab")
            assert state(n)["focus"] != "approve", state(n)["focus"]
        x("xdotool key space")
        machine.sleep(0.5)
        assert state(n)["result"] is None, state(n)
        x("xdotool key ctrl+Return")
        rc, out = card_result(n, "ctrl-enter")
        assert rc == 0 and out == "", (rc, out)
        rc, out = wait_bg()
        assert rc == 0 and out.strip() == "root", (rc, out)

    with subtest("the review lands in the open card, in place; agent and reviewer text stay plain"):
        machine.succeed("echo card > /tmp/reviewer-mode")
        n0 = card_count()
        start_bg("ada", "cd ~ && sudo --why '<b>read</b> the saved reviews & check the format' sh ./check.sh")
        n = wait_card(n0)
        s = wait_state(n, '.review.state == "pending"')
        assert s["texts"]["review_line"] == "Reviewer is reading this request\u2026", s["texts"]
        assert s["texts"]["why"] == "Reason: <b>read</b> the saved reviews & check the format", s["texts"]
        machine.screenshot("card-pending")
        # The human selects a word in the reason while the review is pending.
        click(n, "why", "click --repeat 2 1")
        s = wait_state(n, '.selections.why')
        sel, pid, xid = s["selections"]["why"], s["pid"], s["xid"]
        # Ctrl+C copies it.
        x("xdotool key ctrl+c")
        copied = x("xclip -o -selection clipboard")
        assert copied and copied in s["texts"]["why"], copied
        s = wait_state(n, '.review.state == "ok" and .review_updates == 1')
        assert (s["pid"], s["xid"]) == (pid, xid), "the card was replaced, not updated"
        assert s["selections"].get("why") == sel, ("selection lost", s["selections"])
        tx = s["texts"]
        assert tx["review_badge"] == "LOW", tx
        assert tx["review_headline"] == "approve \u00b7 Read-only, but shows ada other agents' approval records.", tx
        assert tx["review_note_0"] == "\u2022 Output returns to ada, including other agents' requests and reviews.", tx
        assert tx["review_note_1"] == "\u2022 <b>not bold</b> & <i>plain</i>", tx
        assert s["markup"] == [], s["markup"]
        assert not s["details_open"]
        machine.screenshot("card-reviewed")
        click(n, "info")
        s = wait_state(n, '.details_open and .files != null')
        assert "cat \"$d/review.json\"" in s["files"] and "(runs; the snapshot is what runs)" in s["files"], s["files"]
        assert s["texts"]["summary"].startswith("Lists and prints review.json"), s["texts"]
        assert s["texts"]["not_shown"] == "\u2022 Which agents own the two newest directories.", s["texts"]
        assert s["focus"] != "approve", s["focus"]
        machine.sleep(1)
        machine.screenshot("card-details")
        # The expanded card is still all on the screen (Approve is reachable).
        r = i3_card()["rect"]
        screen_h = int(x("xdotool getdisplaygeometry").split()[1])
        assert r["y"] + r["height"] <= screen_h, (r, screen_h)
        click(n, "approve")
        rc, _ = card_result(n)
        assert rc == 0
        rc, out = wait_bg()
        assert rc == 0, (rc, out)

    with subtest("a review without a headline (older reviewers) reads as before"):
        machine.succeed("echo slow > /tmp/reviewer-mode")
        n0 = card_count()
        start_bg("ada", "sudo true")
        n = wait_card(n0)
        s = wait_state(n, '.review.state == "ok"')
        assert s["texts"]["review_badge"] == "MEDIUM", s["texts"]
        assert s["texts"]["review_headline"] == "ask \u00b7 slow review", s["texts"]
        x("xdotool key Escape Escape")
        assert card_result(n, "reason-escape") == (1, "")
        wait_bg()
        machine.succeed("echo ok > /tmp/reviewer-mode")

    with subtest("decrypt: the broker's note is on the card"):
        machine.succeed(
            "su - human -c \"gpg --batch --passphrase \'\' --quick-gen-key test@nuketown default default never\"",
            "echo AGE-SECRET-KEY-TEST > /tmp/key.txt",
            "su - human -c 'gpg --batch --yes -r test@nuketown -o /tmp/key.gpg -e /tmp/key.txt'",
            "chmod 644 /tmp/key.gpg && rm /tmp/key.txt",
        )
        n0 = card_count()
        start_bg("ada", "sudoex --decrypt /tmp/key.gpg:/run/sops-age/keys.txt -- cat /run/sops-age/keys.txt")
        n = wait_card(n0)
        s = state(n)
        assert s["texts"]["note"].startswith("This also unlocks secrets with your GPG key."), s["texts"]
        click(n, "approve")
        rc, out = wait_bg()
        assert rc == 0 and out.strip() == "AGE-SECRET-KEY-TEST", (rc, out)
        machine.succeed(as_ada("sops-lock"))

    with subtest("SIGTERM (a touch approved, or the requester left) denies quietly"):
        n0 = card_count()
        start_bg("ada", "sudo true")
        n = wait_card(n0)
        machine.succeed(f"kill -TERM {state(n)['pid']}")
        assert card_result(n) == (1, "")
        rc, _ = wait_bg()
        assert rc == 1

    with subtest("no answer: the card denies after the timeout, as zenity did"):
        n0 = card_count()
        t0 = time.monotonic()
        start_bg("ada", "sudo quick-cmd")
        n = wait_card(n0)
        s = state(n)
        assert s["texts"]["kind"] == "Kind: quick", s["texts"]
        assert s["texts"]["remaining"] in ("Denies in 0:0${toString timeout}", "Denies in 0:0${toString (timeout - 1)}"), s["texts"]
        rc, out = card_result(n, "timeout")
        assert rc == 1 and out == "no answer within ${toString timeout}s\n", (rc, out)
        assert time.monotonic() - t0 >= ${toString timeout}, time.monotonic() - t0
        rc, out = wait_bg()
        assert rc == 1 and "Reason: no answer within ${toString timeout}s" in out, (rc, out)

    with subtest("Wayland (cage, no XWayland): same card, same keys"):
        wl.wait_for_file("/tmp/wl-state.json", timeout=90)
        wl.wait_until_succeeds("jq -e '.bounds.deny and .focus == \"deny\" and .armed' /tmp/wl-state.json", timeout=60)
        s = json.loads(wl.succeed("cat /tmp/wl-state.json"))
        assert s["backend"] == "GdkWaylandDisplay" and s["xid"] is None, s
        assert s["texts"]["why"] == "Reason: wifi dropped <b>again</b>", s["texts"]
        assert s["texts"]["remaining"] == "", s["texts"]       # prompt_timeout 0: no limit
        wl.screenshot("card-wayland")
        wl.send_key("ret")
        wl.wait_until_succeeds("jq -e '.focus == \"reason\"' /tmp/wl-state.json", timeout=30)
        wl.send_chars("wayland ok\n")
        wl.wait_for_file("/tmp/wl-rc", timeout=30)
        assert wl.succeed("cat /tmp/wl-rc").strip() == "1"
        assert wl.succeed("cat /tmp/wl-stdout") == "wayland ok\n"
  '';
}
