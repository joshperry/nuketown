# VM test: the built-in nixos-switch kind end to end.
#
# The "new system" is a specialisation of the VM (registered in its store
# database) that adds a sudo rule, a user and an /etc file. ada builds
# nothing: ./result in a git checkout points at it, and `nuketown-switch`
# asks for `nuketown-apply <store path>` with the sops age key decrypted
# first. The reviewer is the built-in review command with a fake `claude`
# that keeps what it was given.
#
#   nix build .#checks.x86_64-linux.vm-approval-switch-kind

{ pkgs, nuketownModule, home-manager, impermanence, sops-nix, nixpkgs-unstable }:

pkgs.testers.runNixOSTest {
  name = "nuketown-approval-switch-kind";
  node.pkgsReadOnly = false;

  nodes.machine = { config, lib, pkgs, ... }: {
    imports = [
      (import ./approval-node.nix {
        inherit nuketownModule home-manager impermanence sops-nix nixpkgs-unstable;
      })
    ];
    virtualisation.memorySize = 2048;
    # `switch` installs the boot loader; the test VM boots without one.
    boot.loader.grub.enable = false;
    environment.systemPackages = [ pkgs.git ];

    specialisation.extra.configuration = {
      environment.etc."switch-marker".text = "new\n";
      users.users.carol = { isNormalUser = true; uid = 1200; };
      security.sudo.extraRules = [
        { users = [ "bob" ]; commands = [{ command = "ALL"; options = [ "NOPASSWD" ]; }]; }
      ];
    };
    # The specialisation must be a valid path in the VM's store database
    # (the test VM registers only what additionalPaths lists). Children
    # inherit this module, and have no specialisations of their own.
    virtualisation.additionalPaths = lib.optional (config.specialisation ? extra)
      config.specialisation.extra.configuration.system.build.toplevel;

    # The built-in review command, with a fake claude that keeps its input.
    nuketown.approval.reviewer.command = lib.mkForce null;
    users.users.reviewer.packages = [
      (pkgs.writeShellScriptBin "claude" ''
        n=$(${pkgs.coreutils}/bin/ls /tmp/claude-inputs | ${pkgs.coreutils}/bin/wc -l)
        ${pkgs.coreutils}/bin/cat > /tmp/claude-inputs/$((n + 1)).md
        echo "$*" > /tmp/claude-inputs/$((n + 1)).args
        echo '{"headline": "Adds user carol and lets bob run anything as root.",
               "summary": "fake review", "risk": "high", "recommendation": "ask",
               "notes": [], "not_shown": []}'
      '')
    ];
  };

  testScript = builtins.readFile ./approval-lib.py + ''
    setup()
    machine.succeed("mkdir -p /tmp/claude-inputs && chmod 1777 /tmp/claude-inputs")
    spec = machine.succeed("readlink -f /run/current-system/specialisation/extra").strip()
    cur = machine.succeed("readlink -f /run/current-system").strip()
    assert spec.startswith("/nix/store/") and spec != cur, (spec, cur)

    # The sops age key, encrypted to the human's gpg key.
    machine.succeed(
        "su - human -c \"gpg --batch --passphrase ''' --quick-gen-key test@nuketown default default never\"",
        "echo AGE-SECRET-KEY-TEST > /tmp/key.txt",
        "su - human -c 'gpg --batch --yes -r test@nuketown -o /tmp/key.gpg -e /tmp/key.txt'",
        "cp /tmp/key.gpg /etc/sops-age-key.gpg && chmod 644 /etc/sops-age-key.gpg && rm /tmp/key.txt",
    )

    # ada's checkout: one commit, one uncommitted change, ./result -> spec.
    machine.succeed(as_ada(f"""
      set -e
      mkdir -p ~/cfg && cd ~/cfg && git init -q -b main
      echo '{{ }}' > configuration.nix && git add .
      git -c commit.gpgsign=false commit -q -m 'add carol and a sudo rule for bob'
      echo '# wip' >> configuration.nix
      ln -s {spec} result
    """))
    head = machine.succeed(as_ada("git -C ~/cfg rev-parse HEAD")).strip()

    def refused(cmd, why):
        n0 = prompt_count()
        rc, out = machine.execute(as_ada(cmd + " 2>&1"))
        assert rc != 0 and why in out, (cmd, rc, out)
        assert prompt_count() == n0, f"{cmd}: a card was shown"
        rec = [r for r in journal_records() if r["argv"][:1] == ["nuketown-apply"]][-1]
        assert rec["decision"] == "refused" and rec["kind"] == "nixos-switch", rec
        return out

    with subtest("the collector refuses anything but a NixOS system's store path"):
        answer("approve")
        refused("sudo nuketown-apply /etc", "is not a /nix/store path")
        jq = machine.succeed("dirname $(dirname $(readlink -f $(command -v jq)))").strip()
        refused(f"sudo nuketown-apply {jq}", "is not a NixOS system")
        refused("sudo nuketown-apply /run/current-system", "is not a /nix/store path")
        refused(f"sudo nuketown-apply {spec}/", "is not a /nix/store path")
        refused(f"sudo nuketown-apply {spec} extra", "one argument")
        refused(f"sudo -u bob nuketown-apply {spec}", "runs as root")
        refused("sudo nuketown-apply /nix/store/00000000000000000000000000000000-nixos-system-x",
                "is not a directory")
        # Nothing switched.
        assert machine.succeed("readlink -f /run/current-system").strip() == cur
        machine.fail("test -e /etc/switch-marker")

    with subtest("nuketown-apply refuses the same things when root runs it directly"):
        out = machine.fail("nuketown-apply /etc 2>&1")
        assert "is not a /nix/store path" in out, out
        out = machine.fail(f"nuketown-apply {jq} 2>&1")
        assert "is not a NixOS system" in out, out

    with subtest("nuketown-switch: kind nixos-switch, root's evidence for the card and the reviewer"):
        answer("deny")
        n0 = prompt_count()
        # Hold the card until the review has landed.
        machine.succeed("rm -f /tmp/prompter-go && touch /tmp/prompter-wait")
        start_bg("ada", "cd ~/cfg && nuketown-switch --why 'add carol and a sudo rule for bob' 2>&1")
        machine.wait_until_succeeds(f"test -e /tmp/prompts/{n0 + 1}/request.json", timeout=60)
        d = machine.succeed(f"cat /tmp/prompts/{n0 + 1}/dir").strip()
        machine.wait_until_succeeds(f"jq -e '.status != \"pending\"' {d}/review.json", timeout=30)
        machine.succeed("rm /tmp/prompter-wait && touch /tmp/prompter-go")
        rc, out = wait_bg()
        assert rc == 1 and "Request denied." in out, (rc, out)
        n, req, _ = last_prompt()
        assert n == n0 + 1
        assert req["kind"]["name"] == "nixos-switch", req["kind"]
        assert req["kind"]["review_prompt"].endswith("nuketown-nixos-switch-prompt.md"), req["kind"]
        assert req["argv"] == ["nuketown-apply", spec], req["argv"]
        assert req["exec_argv"][0] == "/run/current-system/sw/bin/nuketown-apply", req["exec_argv"]
        assert req["decrypt"] == ["/etc/sops-age-key.gpg:/run/sops-age/keys.txt"], req["decrypt"]
        assert req["why"] == "add carol and a sudo rule for bob", req["why"]
        assert req["snapshots"] == [], req["snapshots"]
        assert req["prompt_timeout"] == 600, req
        k = f"/tmp/prompts/{n}/kind"
        files = machine.succeed(f"ls {k}").split()
        for f in ["system.txt", "nvd-diff.txt", "sudoers.diff", "access.diff", "activate.diff",
                  "units.diff", "git.txt"]:
            assert f in files, (f, files)
        cat = lambda f: machine.succeed(f"cat {k}/{f}")
        system = cat("system.txt")
        print(system)
        assert f"new system:     {spec}" in system and f"running system: {cur}" in system, system
        assert "switch program: same as the running system's" in system, system
        assert "etc/sudoers" in system and "users and groups" in system, system
        assert "<<< " + cur in cat("nvd-diff.txt") and ">>> " + spec in cat("nvd-diff.txt"), cat("nvd-diff.txt")
        sudoers = cat("sudoers.diff")
        print(sudoers)
        assert "== etc/sudoers: CHANGED" in sudoers and "\n+bob" in sudoers, sudoers
        access = cat("access.diff")
        assert "\n+user carol " in access and '"uid":1200' in access, access
        assert "\n-user carol" not in access
        assert cat("units.diff").startswith("added:"), cat("units.diff")
        git = cat("git.txt")
        print(git)
        assert f"HEAD:       {head}" in git, git
        assert "subject:    add carol and a sudo rule for bob" in git, git
        assert "working tree: DIRTY" in git and "configuration.nix" in git and "+# wip" in git, git
        assert "repository: /agents/ada/cfg" in git, git
        # git ran as ada, read-only: no index refresh or lock left behind.
        machine.fail("test -e /agents/ada/cfg/.git/index.lock")
        assert machine.succeed("stat -c %U /agents/ada/cfg/.git/index").strip() == "ada"

        # The reviewer: the kind's prompt, request.json and every kind file.
        rev = review_at_answer(n)
        assert rev["status"] == "ok" and rev["risk"] == "high", rev
        given = machine.succeed("cat /tmp/claude-inputs/$(ls /tmp/claude-inputs | grep -c md).md")
        assert "That alone is not a finding." in given and "normal nuketown-switch flow" in given, given[:400]
        for f in ["system.txt", "nvd-diff.txt", "sudoers.diff", "access.diff", "activate.diff",
                  "units.diff", "git.txt"]:
            assert f"\n## kind/{f}\n" in given, f
        assert "\n+bob" in given and "## request.json" in given
        assert "You are the adversarial reviewer for a sudo request" not in given, "default prompt used"
        # Nothing switched; the key is locked again.
        assert machine.succeed("readlink -f /run/current-system").strip() == cur
        machine.fail("test -e /run/sops-age/keys.txt")
        rec = [r for r in journal_records() if r["id"] == req["id"]][-1]
        assert rec["decision"] == "denied" and rec["kind"] == "nixos-switch", rec

    with subtest("approve switches the machine to exactly that system"):
        answer("approve")
        rc, out = machine.execute(as_ada("cd ~/cfg && nuketown-switch 2>&1"))
        print(out)
        assert rc == 0, (rc, out)
        _, req, _ = last_prompt()
        assert req["kind"]["name"] == "nixos-switch" and req["argv"] == ["nuketown-apply", spec], req
        assert req["why"].startswith("switch to " + spec.split("/")[-1]), req["why"]
        assert machine.succeed("readlink -f /run/current-system").strip() == spec
        assert machine.succeed("readlink -f /nix/var/nix/profiles/system").strip() == spec
        assert machine.succeed("cat /etc/switch-marker").strip() == "new"
        machine.succeed("id carol")
        machine.fail("test -e /run/sops-age/keys.txt")
        rec = [r for r in journal_records() if r["id"] == req["id"]][-1]
        assert rec["decision"] == "approved" and rec["exit"] == 0 and rec["kind"] == "nixos-switch", rec
  '';
}
