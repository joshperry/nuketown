# VM test: decrypt + command never shows gpg's PIN prompt while the
# approval dialog is up, and (touchApproves) an already-unlocked key
# approves without anyone answering the dialog.
#
# The human's key has a passphrase and gpg-agent uses a fake pinentry that
# logs when it is asked. "Unlocked" is the agent's passphrase cache here,
# standing in for a YubiKey whose PIN was entered earlier (where the touch
# is the human action).
#
#   nix build .#checks.x86_64-linux.vm-approval-decrypt

{ pkgs, nuketownModule, home-manager, impermanence, sops-nix, nixpkgs-unstable }:

pkgs.testers.runNixOSTest {
  name = "nuketown-approval-decrypt";
  node.pkgsReadOnly = false;

  nodes.machine = { pkgs, ... }: {
    imports = [
      (import ./approval-node.nix {
        inherit nuketownModule home-manager impermanence sops-nix nixpkgs-unstable;
        touchApproves = true;
      })
    ];
    environment.etc."fake-pinentry" = {
      mode = "0755";
      text = ''
        #!${pkgs.bash}/bin/bash
        echo "OK fake pinentry"
        while IFS= read -r line; do
          case "$line" in
            GETPIN*)
              ${pkgs.coreutils}/bin/date +%s.%N >> /tmp/pinentry-called
              echo "D testpass"; echo OK ;;
            BYE*) echo OK; exit 0 ;;
            *) echo OK ;;
          esac
        done
      '';
    };
  };

  testScript = builtins.readFile ./approval-lib.py + ''
    setup()
    machine.succeed("echo disabled > /tmp/reviewer-mode")
    machine.succeed(
        "su - human -c 'mkdir -p -m 700 ~/.gnupg && echo pinentry-program /etc/fake-pinentry > ~/.gnupg/gpg-agent.conf'",
        "su - human -c 'gpg --batch --pinentry-mode loopback --passphrase testpass --quick-gen-key test@nuketown default default never'",
        "echo AGE-SECRET-KEY-TEST > /tmp/key.txt",
        "su - human -c 'gpg --batch --yes -r test@nuketown -o /tmp/key.gpg -e /tmp/key.txt'",
        "chmod 644 /tmp/key.gpg && rm /tmp/key.txt",
        # Forget any cached passphrase: the key starts locked.
        "su - human -c 'gpgconf --kill gpg-agent'",
        "rm -f /tmp/pinentry-called",
    )
    switch = "sudoex --decrypt /tmp/key.gpg:/run/sops-age/keys.txt -- cat /run/sops-age/keys.txt"

    with subtest("decrypt-after-approve: no PIN prompt while the dialog is up"):
        answer("approve")
        machine.succeed("rm -f /tmp/prompter-go && touch /tmp/prompter-wait")
        n0 = prompt_count()
        start_bg("ada", switch)
        machine.wait_until_succeeds(f"test -e /tmp/prompts/{n0 + 1}/request.json", timeout=60)
        # The touch-only attempt needs a PIN, so it fails without asking.
        machine.sleep(3)
        machine.fail("test -e /tmp/pinentry-called")
        machine.succeed("rm /tmp/prompter-wait && touch /tmp/prompter-go")
        rc, out = wait_bg()
        assert rc == 0 and out.strip() == "AGE-SECRET-KEY-TEST", (rc, out)
        answered = float(machine.succeed(f"cat /tmp/prompts/{n0 + 1}/answered"))
        asked = [float(t) for t in machine.succeed("cat /tmp/pinentry-called").split()]
        assert len(asked) == 1 and asked[0] > answered, (asked, answered)
        machine.succeed(as_ada("sops-lock"))

    with subtest("touchApproves: an unlocked key approves with the dialog unanswered"):
        machine.succeed("rm -f /tmp/prompter-go && touch /tmp/prompter-wait")
        n0 = prompt_count()
        start_bg("ada", switch)
        rc, out = wait_bg()
        assert rc == 0 and out.strip() == "AGE-SECRET-KEY-TEST", (rc, out)
        assert prompt_count() == n0 + 1
        machine.fail(f"test -e /tmp/prompts/{n0 + 1}/answered")
        assert len(machine.succeed("cat /tmp/pinentry-called").split()) == 1
        machine.succeed("rm /tmp/prompter-wait")

    with subtest("deny while the key is locked: no PIN prompt at all"):
        machine.succeed("su - human -c 'gpgconf --kill gpg-agent'")
        machine.succeed(as_ada("sops-lock"))
        answer("deny")
        before = len(machine.succeed("cat /tmp/pinentry-called").split())
        machine.fail(as_ada(switch))
        assert len(machine.succeed("cat /tmp/pinentry-called").split()) == before
        machine.fail("test -e /run/sops-age/keys.txt")
  '';
}
