# VM test: agents can't get root without the human approving, and the
# human sees exactly what will run.
#
#   nix build .#checks.x86_64-linux.vm-sudo-approval-bypass

{ pkgs, nuketownModule, home-manager, impermanence, sops-nix, nixpkgs-unstable }:

pkgs.testers.runNixOSTest {
  name = "nuketown-sudo-approval-bypass";
  node.pkgsReadOnly = false;

  nodes.machine = import ./approval-node.nix {
    inherit nuketownModule home-manager impermanence sops-nix nixpkgs-unstable;
  };

  testScript = builtins.readFile ./approval-lib.py + ''
    setup()

    with subtest("agents have no sudo rule that reaches root"):
        rules = machine.succeed("sudo -l -U ada")
        assert "(nuketown-approval) NOPASSWD: /run/current-system/sw/bin/nuketown-approve" in rules, rules
        assert "(root)" not in rules and "(ALL" not in rules, rules
        machine.fail(as_ada("/run/wrappers/bin/sudo -n -u root /run/current-system/sw/bin/id"))
        machine.fail("test -e /run/current-system/sw/bin/sudoex-run")
        machine.fail("test -e /run/current-system/sw/bin/sudo-with-approval")

    with subtest("agents can't talk to the broker"):
        machine.fail(as_ada("echo REQUEST:x | socat - UNIX-CONNECT:/run/nuketown-broker/socket"))

    with subtest("no SETENV: BASH_ENV / -E can't influence the service user"):
        machine.succeed("echo 'touch /tmp/bash-env-ran' > /tmp/pwn && chmod 644 /tmp/pwn")
        machine.fail(as_ada("/run/wrappers/bin/sudo BASH_ENV=/tmp/pwn -u nuketown-approval /run/current-system/sw/bin/nuketown-approve -- /run/current-system/sw/bin/true"))
        machine.fail(as_ada("BASH_ENV=/tmp/pwn /run/wrappers/bin/sudo -E -u nuketown-approval /run/current-system/sw/bin/nuketown-approve -- /run/current-system/sw/bin/true"))
        machine.fail("test -e /tmp/bash-env-ran")

    with subtest("denied commands don't run"):
        answer("deny")
        n0 = prompt_count()
        out = machine.fail(as_ada("sudo touch /root/denied 2>&1"))
        assert "Request denied." in out, out
        machine.fail("test -e /root/denied")
        assert prompt_count() == n0 + 1

    with subtest("a newline in argv is one argument, shown quoted"):
        n0 = prompt_count()
        machine.fail(as_ada("""sudo sh -c "$(printf 'true\\nSUDO:ada:ls')" """))
        assert prompt_count() == n0 + 1
        _, req, _ = last_prompt()
        assert req["argv"] == ["sh", "-c", "true\nSUDO:ada:ls"], req["argv"]
        assert req["display"] == "sh -c $'true\\nSUDO:ada:ls'", req["display"]

    with subtest("--decrypt rejects a newline, before asking"):
        n0 = prompt_count()
        machine.fail(as_ada("""sudoex --decrypt "$(printf 'a:b\\nREQUEST:x')" -- true"""))
        assert prompt_count() == n0

    with subtest("a file the agent can't read is refused, not read as root"):
        machine.succeed("printf '#!/bin/sh\\ntouch /tmp/secret-ran\\n' > /var/lib/secret.sh && chmod 700 /var/lib/secret.sh")
        n0 = prompt_count()
        out = machine.fail(as_ada("sudo /var/lib/secret.sh 2>&1"))
        assert "cannot read" in out, out
        out = machine.fail(as_ada("sudo bash /var/lib/secret.sh 2>&1"))
        assert "cannot read" in out, out
        assert prompt_count() == n0
        machine.fail("test -e /tmp/secret-ran")

    with subtest("approval list is enforced before asking"):
        answer("approve")
        n0 = prompt_count()
        assert machine.succeed(as_user("eve", "sudo id -un")).strip() == "root"
        out = machine.fail(as_user("eve", "sudo true 2>&1"))
        assert "not in sudo.approvalAllow" in out, out
        assert prompt_count() == n0 + 1

    with subtest("mock mode (root-only file) still works"):
        machine.succeed("echo MOCK_DENIED > /run/nuketown-broker/mode")
        n0 = prompt_count()
        out = machine.fail(as_ada("sudo true 2>&1"))
        assert "[MOCK] Auto-denied" in out, out
        assert prompt_count() == n0
        machine.fail(as_ada("echo MOCK_APPROVED > /run/nuketown-broker/mode"))
        machine.succeed("rm /run/nuketown-broker/mode")
  '';
}
