# VM test: the approval flow end to end with the real broker, a stub
# prompter and a stub reviewer.
#
#   nix build .#checks.x86_64-linux.vm-approval-flow

{ pkgs, nuketownModule, home-manager, impermanence, sops-nix, nixpkgs-unstable }:

pkgs.testers.runNixOSTest {
  name = "nuketown-approval-flow";
  node.pkgsReadOnly = false;

  nodes.machine = import ./approval-node.nix {
    inherit nuketownModule home-manager impermanence sops-nix nixpkgs-unstable;
  };

  testScript = builtins.readFile ./approval-lib.py + ''
    setup()
    answer("approve")

    with subtest("stdout and exit code pass through"):
        rc, out = machine.execute(as_ada("sudo sh -c 'id -un; echo hello; exit 7'"))
        assert rc == 7, rc
        assert out == "root\nhello\n", repr(out)

    with subtest("sudo -u is honoured"):
        assert machine.succeed(as_ada("sudo -u bob id -un")).strip() == "bob"
        _, req, _ = last_prompt()
        assert req["run_as"]["user"] == "bob", req["run_as"]

    with subtest("relative paths resolve from the agent's directory"):
        machine.succeed(as_ada("mkdir -p ~/w && echo data > ~/w/f && cd ~/w && sudo cp f /root/copied"))
        assert machine.succeed("cat /root/copied").strip() == "data"

    with subtest("the snapshot runs, not the file as it is after approval"):
        script = "#!/bin/sh\necho ORIGINAL > /tmp/snap-result\n"
        for form in ["bash ./s.sh", "./s.sh"]:
            machine.succeed("rm -f /tmp/snap-result /tmp/prompter-go && touch /tmp/prompter-wait")
            machine.succeed(as_ada(f"cd ~ && printf '{script}' > s.sh && chmod 755 s.sh"))
            n0 = prompt_count()
            machine.succeed(as_user("ada", f"cd ~ && sudo --why 'write a marker' {form}", "/tmp/bg.sh")
                            + " > /tmp/bg.out 2>&1 &")
            machine.wait_until_succeeds(f"test -e /tmp/prompts/{n0 + 1}/request.json", timeout=60)
            machine.succeed(as_ada("cd ~ && sed -i s/ORIGINAL/MODIFIED/ s.sh"))
            machine.succeed("rm /tmp/prompter-wait && touch /tmp/prompter-go")
            machine.wait_until_succeeds("test -e /tmp/snap-result", timeout=60)
            assert machine.succeed("cat /tmp/snap-result").strip() == "ORIGINAL", form
            _, req, _ = last_prompt()
            snaps = [s for s in req["snapshots"] if s["executed"]]
            assert len(snaps) == 1 and snaps[0]["path"] == "/agents/ada/s.sh", req["snapshots"]
            assert req["why"] == "write a marker"
            # The reviewer saw the same bytes that ran.
            assert "ORIGINAL" in machine.succeed(f"cat /tmp/prompts/{n0 + 1}/{snaps[0]['snapshot']}")

    with subtest("reviewer output reaches the prompter"):
        machine.succeed("echo ok > /tmp/reviewer-mode")
        machine.succeed(as_ada("sudo true"))
        _, req, rev = last_prompt()
        assert rev["status"] == "ok" and rev["summary"] == "runs " + req["display"], rev
        assert rev["risk"] == "low" and rev["recommendation"] == "approve", rev

    with subtest("hung reviewer: asked anyway, review unavailable"):
        machine.succeed("echo hang > /tmp/reviewer-mode")
        n0 = prompt_count()
        machine.succeed(as_ada("sudo true"))
        assert prompt_count() == n0 + 1
        _, _, rev = last_prompt()
        assert rev["status"] == "unavailable" and "timed out" in rev["reason"], rev

    with subtest("garbage / failing reviewer: asked anyway"):
        for mode, why in [("garbage", "not valid"), ("fail", "exit 9")]:
            machine.succeed(f"echo {mode} > /tmp/reviewer-mode")
            machine.succeed(as_ada("sudo true"))
            _, _, rev = last_prompt()
            assert rev["status"] == "unavailable" and why in rev["reason"], rev
        machine.succeed("echo ok > /tmp/reviewer-mode")

    with subtest("sudoex --decrypt is one request, decrypt then run"):
        machine.succeed(
            "su - human -c \"gpg --batch --passphrase ''' --quick-gen-key test@nuketown default default never\"",
            "echo AGE-SECRET-KEY-TEST > /tmp/key.txt",
            "su - human -c 'gpg --batch --yes -r test@nuketown -o /tmp/key.gpg -e /tmp/key.txt'",
            "chmod 644 /tmp/key.gpg && rm /tmp/key.txt",
        )
        n0 = prompt_count()
        out = machine.succeed(as_ada("sudoex --decrypt /tmp/key.gpg:/run/sops-age/keys.txt -- cat /run/sops-age/keys.txt"))
        assert out.strip() == "AGE-SECRET-KEY-TEST", out
        assert prompt_count() == n0 + 1
        _, req, _ = last_prompt()
        assert req["decrypt"] == ["/tmp/key.gpg:/run/sops-age/keys.txt"], req["decrypt"]
        machine.succeed(as_ada("sops-lock"))
        machine.fail("test -e /run/sops-age/keys.txt")

    with subtest("audit: journal record and persisted request dir"):
        machine.execute(as_ada("sudo sh -c 'exit 3'"))
        recs = [json.loads(l) for l in machine.succeed("journalctl -t nuketown-approval -o cat").splitlines() if l.startswith("{")]
        rec = [r for r in recs if r["argv"] == ["sh", "-c", "exit 3"]][-1]
        assert rec["requester"] == "ada" and rec["exit"] == 3 and rec["decision"] == "approved", rec
        assert rec["review"]["status"] == "ok", rec
        machine.succeed(f"test -f /var/lib/nuketown-approval/{rec['id']}/request.json")
        machine.succeed(f"test -f /var/lib/nuketown-approval/{rec['id']}/decision.json")
        machine.fail(f"test -e /run/nuketown-approval/{rec['id']}")
        # Each privileged step is a logged sudo call by the service user.
        sudolog = machine.succeed("journalctl -t sudo -o cat")
        assert "nuketown-approval : " in sudolog and "COMMAND=" in sudolog, sudolog
  '';
}
