# VM test: the approval wrappers can't be used to get root without the
# broker approving, and the broker sees exactly what will run.
#
# A fake broker (socat as the human user) records each request and
# answers with whatever is in /tmp/broker-answer.
#
#   nix build .#checks.x86_64-linux.vm-sudo-approval-bypass

{ pkgs, nuketownModule, home-manager, impermanence, sops-nix, nixpkgs-unstable }:

pkgs.testers.runNixOSTest {
  name = "nuketown-sudo-approval-bypass";
  node.pkgsReadOnly = false;

  nodes.machine = { pkgs, ... }: {
    imports = [
      nuketownModule
      home-manager.nixosModules.home-manager
      impermanence.nixosModules.impermanence
      sops-nix.nixosModules.sops
    ];
    nixpkgs.overlays = [
      (_: _: { unstable = import nixpkgs-unstable { system = pkgs.system; }; })
    ];
    home-manager.useGlobalPkgs = true;
    home-manager.useUserPackages = true;

    users.users.human = { uid = 1000; isNormalUser = true; };
    home-manager.users.human.home.stateVersion = "25.11";

    nuketown = {
      enable = true;
      domain = "nuketown.test";
      humanUser = "human";
      agents.ada = {
        enable = true;
        uid = 1100;
        sudo.enable = true;
      };
    };

    systemd.services.fake-broker = {
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      serviceConfig = {
        User = "human";
        ExecStart = "${pkgs.socat}/bin/socat UNIX-LISTEN:/run/nuketown-broker/socket,fork,mode=660 EXEC:${pkgs.writeShellScript "fake-broker-handler" ''
          while IFS= read -r line && [ -n "$line" ]; do
            printf '%s\n' "$line" >> /tmp/broker-requests
          done
          printf -- '--\n' >> /tmp/broker-requests
          cat /tmp/broker-answer
        ''}";
      };
    };
  };

  testScript = ''
    # Run cmd as ada from a script file, so it needs no extra quoting.
    def as_ada(cmd):
        machine.succeed(f"cat > /tmp/as-ada.sh <<'EOF'\n{cmd}\nEOF\nchmod 755 /tmp/as-ada.sh")
        return "su - ada -s /bin/sh -c 'bash /tmp/as-ada.sh'"

    machine.wait_for_unit("fake-broker.service")
    machine.wait_for_file("/run/nuketown-broker/socket")
    machine.succeed("echo DENIED > /tmp/broker-answer && chmod 644 /tmp/broker-answer")

    with subtest("sudoex-run is not a password-less root shell"):
        machine.fail(as_ada("/run/wrappers/bin/sudo /run/current-system/sw/bin/sudoex-run touch /root/sudoex-bypass"))
        machine.fail("test -e /root/sudoex-bypass")

    with subtest("sudoex goes through the broker"):
        machine.fail(as_ada("sudoex touch /root/sudoex-denied"))
        machine.fail("test -e /root/sudoex-denied")
        machine.succeed("grep -qx 'SUDO:ada:touch /root/sudoex-denied' /tmp/broker-requests")

    with subtest("no SETENV: BASH_ENV can't run code as root before approval"):
        machine.succeed("echo 'touch /root/bash-env-bypass' > /tmp/pwn && chmod 644 /tmp/pwn")
        for wrapper in ["sudo-with-approval", "sudoex-run"]:
            machine.fail(as_ada(f"/run/wrappers/bin/sudo BASH_ENV=/tmp/pwn /run/current-system/sw/bin/{wrapper} true"))
        machine.fail("test -e /root/bash-env-bypass")

    with subtest("a newline in argv can't add a request line"):
        machine.succeed("rm -f /tmp/broker-requests")
        machine.fail(as_ada("""/run/wrappers/bin/sudo /run/current-system/sw/bin/sudo-with-approval sh -c "$(printf 'true\\nSUDO:ada:ls')" """))
        out = machine.succeed("cat /tmp/broker-requests")
        assert out.count("\n") == 2, f"expected one request line + terminator, got: {out!r}"
        assert out.startswith("SUDO:ada:sh -c $'true\\nSUDO:ada:ls'"), out

    with subtest("--decrypt rejects a newline"):
        machine.succeed("rm -f /tmp/broker-requests")
        machine.fail(as_ada("""sudoex --decrypt "$(printf 'a:b\\nSUDO:ada:ls')" -- true"""))
        machine.fail("test -e /tmp/broker-requests")

    with subtest("approved commands still run as root"):
        machine.succeed("echo APPROVED > /tmp/broker-answer")
        machine.succeed(as_ada("sudo touch /root/approved-sudo"))
        machine.succeed(as_ada("sudoex touch /root/approved-sudoex"))
        machine.succeed("test -e /root/approved-sudo -a -e /root/approved-sudoex")
  '';
}
