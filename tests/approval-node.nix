# Shared VM node for the approval tests.
#
# - human runs the real broker (home-manager approvalDaemon, lingering so
#   it starts at boot) with a stub prompter: it records each request
#   directory under /tmp/prompts/<n>/ and answers with the contents of
#   /tmp/prompter-answer (approve|deny), denying with the reason in
#   /tmp/prompter-reason if present. If /tmp/prompter-wait exists it
#   waits for /tmp/prompter-go before answering. review.json as it was
#   when answering is kept as review-at-answer.json.
# - reviewer runs a stub review command whose behaviour comes from
#   /tmp/reviewer-mode (ok|slow|hang|garbage|fail). The prompt is shown
#   after promptDelay (2 s) even while the review is still running.
# - kind "demo" for kind-cmd: its collector writes kind/diff.txt, or
#   refuses (exit 5) when /tmp/collect-refuse exists.
# - ada (any command) and eve (approvalAllow = [ "id" ]) can sudo;
#   bob is a plain user to test `sudo -u`.

{ nuketownModule, home-manager, impermanence, sops-nix, nixpkgs-unstable, touchApproves ? false }:

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
    ${pkgs.coreutils}/bin/cp "$1/review.json" "$d/review-at-answer.json"
    ${pkgs.coreutils}/bin/date +%s.%N > "$d/answered"
    if [ "$(${pkgs.coreutils}/bin/cat /tmp/prompter-answer)" = approve ]; then exit 0; fi
    ${pkgs.coreutils}/bin/cat /tmp/prompter-reason 2>/dev/null
    exit 1
  '';

  kindCmd = pkgs.writeShellScriptBin "kind-cmd" ''
    echo "dir-has: $(${pkgs.coreutils}/bin/cat "$NUKETOWN_APPROVAL_DIR/kind/diff.txt")"
    ${pkgs.jq}/bin/jq -r .kind.name "$NUKETOWN_APPROVAL_DIR/request.json"
  '';

  collector = pkgs.writeShellScript "demo-collect" ''
    if [ -e /tmp/collect-refuse ]; then
      echo "demo: refused, rebase onto abc123" >&2
      exit 5
    fi
    echo "running as $(${pkgs.coreutils}/bin/id -un)"
    echo DIFF > "$1/kind/diff.txt"
  '';

  reviewer = pkgs.writeShellScript "stub-reviewer" ''
    case "$(${pkgs.coreutils}/bin/cat /tmp/reviewer-mode 2>/dev/null)" in
      ok)
        ${pkgs.jq}/bin/jq -c '{summary: ("runs " + .display), risk: "low",
          recommendation: "approve", notes: ["note <b>"], not_shown: []}' "$1/request.json" ;;
      slow)
        ${pkgs.coreutils}/bin/sleep 4
        echo '{"summary": "slow review", "risk": "medium", "recommendation": "ask"}' ;;
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
    nuketown.approvalDaemon = { enable = true; prompter = "${prompter}"; inherit touchApproves; };
  };

  environment.systemPackages = [ pkgs.socat pkgs.gnupg pkgs.jq kindCmd ];

  nuketown = {
    enable = true;
    domain = "nuketown.test";
    humanUser = "human";
    agents.ada = { enable = true; uid = 1100; sudo.enable = true; };
    agents.reviewer = { enable = true; uid = 1101; };
    agents.eve = { enable = true; uid = 1102; sudo.enable = true; sudo.approvalAllow = [ "id" ]; };
    approval.reviewer = { enable = true; command = "${reviewer}"; timeout = 6; promptDelay = 2; };
    approval.kinds.demo = {
      command = "/run/current-system/sw/bin/kind-cmd";
      collect = "${collector}";
      reviewPrompt = "${pkgs.writeText "demo-prompt.md" "demo prompt"}";
      timeout = 0;
    };
  };
}
