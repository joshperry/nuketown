# Shared VM node for the approval tests.
#
# - human runs the real broker (home-manager approvalDaemon, lingering so
#   it starts at boot) with a stub prompter: it records each request
#   directory under /tmp/prompts/<n>/ and answers with the contents of
#   /tmp/prompter-answer (approve|deny). If /tmp/prompter-wait exists it
#   waits for /tmp/prompter-go before answering.
# - reviewer runs a stub review command whose behaviour comes from
#   /tmp/reviewer-mode (ok|hang|garbage|fail).
# - ada (any command) and eve (approvalAllow = [ "id" ]) can sudo;
#   bob is a plain user to test `sudo -u`.

{ nuketownModule, home-manager, impermanence, sops-nix, nixpkgs-unstable }:

{ pkgs, ... }:

let
  prompter = pkgs.writeShellScript "stub-prompter" ''
    set -u
    n=$(${pkgs.coreutils}/bin/ls /tmp/prompts | ${pkgs.coreutils}/bin/wc -l)
    d=/tmp/prompts/$((n + 1))
    ${pkgs.coreutils}/bin/mkdir -p "$d"
    ${pkgs.coreutils}/bin/cp -r "$1"/. "$d"/
    echo "$1" > "$d/dir"
    if [ -e /tmp/prompter-wait ]; then
      while [ ! -e /tmp/prompter-go ]; do ${pkgs.coreutils}/bin/sleep 0.2; done
    fi
    [ "$(${pkgs.coreutils}/bin/cat /tmp/prompter-answer)" = approve ]
  '';

  reviewer = pkgs.writeShellScript "stub-reviewer" ''
    case "$(${pkgs.coreutils}/bin/cat /tmp/reviewer-mode 2>/dev/null)" in
      ok)
        ${pkgs.jq}/bin/jq -c '{summary: ("runs " + .display), risk: "low",
          recommendation: "approve", notes: ["note <b>"], not_shown: []}' "$1/request.json" ;;
      hang) exec ${pkgs.coreutils}/bin/sleep 600 ;;
      garbage) echo "this is not json" ;;
      *) exit 9 ;;
    esac
  '';
in
{
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

  users.users.human = { uid = 1000; isNormalUser = true; linger = true; };
  users.users.bob = { uid = 1001; isNormalUser = true; };
  home-manager.users.human = {
    imports = [ ../approval-daemon.nix ];
    home.stateVersion = "25.11";
    nuketown.approvalDaemon = { enable = true; prompter = "${prompter}"; };
  };

  environment.systemPackages = [ pkgs.socat pkgs.gnupg pkgs.jq ];

  nuketown = {
    enable = true;
    domain = "nuketown.test";
    humanUser = "human";
    agents.ada = { enable = true; uid = 1100; sudo.enable = true; };
    agents.reviewer = { enable = true; uid = 1101; };
    agents.eve = { enable = true; uid = 1102; sudo.enable = true; sudo.approvalAllow = [ "id" ]; };
    approval.reviewer = { enable = true; command = "${reviewer}"; timeout = 5; };
  };
}
