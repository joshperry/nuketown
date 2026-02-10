# Nix evaluation checks for the nuketown module.
#
# These validate that the module produces the expected NixOS and
# home-manager configuration without booting a VM. Run with:
#
#   nix flake check
#
# Each check is a trivial derivation that fails at eval time if
# any assertion is false, so feedback is instant.

{ nixpkgs, nixpkgs-unstable, home-manager, impermanence, sops-nix, nuketownModule }:

let
  system = "x86_64-linux";
  pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };

  # ── Test Helpers ──────────────────────────────────────────────────

  # Build a NixOS config with nuketown and the given agent configuration.
  # Returns the fully evaluated config attrset.
  evalConfig = nuketownConfig: extraModules:
    (nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        nuketownModule
        home-manager.nixosModules.home-manager
        { home-manager.useGlobalPkgs = true; home-manager.useUserPackages = true; }
        impermanence.nixosModules.impermanence
        sops-nix.nixosModules.sops
        ({ ... }: {
          nixpkgs.overlays = [
            (_: _: {
              unstable = import nixpkgs-unstable {
                inherit system;
                config.allowUnfree = true;
              };
            })
          ];
        })
        ({ ... }: {
          system.stateVersion = "25.11";
          boot.loader.grub.device = "/dev/vda";
          fileSystems."/" = { device = "/dev/vda1"; fsType = "ext4"; };
          users.mutableUsers = false;
          users.users.human = {
            uid = 1000;
            isNormalUser = true;
            extraGroups = [ "wheel" ];
            password = "test";
          };
          home-manager.users.human.home.stateVersion = "25.11";
        })
        nuketownConfig
      ] ++ extraModules;
    }).config;

  # Assert a condition; abort with message if false.
  assertMsg = msg: cond:
    if cond then true
    else builtins.throw "ASSERTION FAILED: ${msg}";

  # Assert a string contains a substring.
  assertContains = desc: haystack: needle:
    assertMsg "${desc}: expected to contain \"${needle}\"" (builtins.isString haystack && nixpkgs.lib.hasInfix needle haystack);

  # Assert a string does NOT contain a substring.
  assertNotContains = desc: haystack: needle:
    assertMsg "${desc}: expected NOT to contain \"${needle}\"" (builtins.isString haystack && !(nixpkgs.lib.hasInfix needle haystack));

  # Assert equality.
  assertEq = desc: actual: expected:
    assertMsg "${desc}: expected ${builtins.toJSON expected}, got ${builtins.toJSON actual}" (actual == expected);

  # Turn a list of assertion results (all must be `true`) into a
  # derivation that succeeds.  If any assertion threw, the whole
  # derivation is unevaluable and `nix flake check` reports the error.
  mkCheck = name: assertions:
    let
      # Force every assertion (they are lazy).
      allPassed = builtins.all (x: x) assertions;
    in
    pkgs.runCommand "nuketown-check-${name}" {} ''
      ${if allPassed then ''
        echo "PASS: ${name}"
        mkdir -p $out
        echo ok > $out/result
      '' else ''
        echo "FAIL: ${name}" >&2
        exit 1
      ''}
    '';


  # ── Test Fixtures ─────────────────────────────────────────────────

  # Minimal agent with claudeCode enabled, sudo, and devices
  fullAgentConfig = { pkgs, ... }: {
    nuketown = {
      enable = true;
      domain = "nuketown.test";
      humanUser = "human";
      agents.ada = {
        enable = true;
        uid = 1100;
        role = "software";
        description = "Test software agent";
        packages = with pkgs; [ unstable.claude-code ];
        persist = [ "projects" ".config/claude" ];
        sudo.enable = true;
        portal.enable = true;
        devices = [
          { subsystem = "tty"; attrs = { idVendor = "0483"; idProduct = "5740"; }; action = "add"; }
          { subsystem = "usb"; attrs = { product = "STM32  BOOTLOADER"; }; }
        ];
        claudeCode = {
          enable = true;
          settings.permissions.defaultMode = "allowEdits";
          extraPrompt = ''
            ## Custom Section
            This is a custom instruction.
          '';
        };
      };
    };
  };

  # Agent with claudeCode disabled (default)
  noClaudeCodeConfig = { pkgs, ... }: {
    nuketown = {
      enable = true;
      domain = "nuketown.test";
      humanUser = "human";
      agents.vox = {
        enable = true;
        uid = 1101;
        role = "research";
        description = "Research agent";
        packages = with pkgs; [ unstable.claude-code ];
        persist = [ "projects" "notes" ];
        sudo.enable = true;
      };
    };
  };

  # Agent with extraAgents and custom agentName
  customNamingConfig = { pkgs, ... }: {
    nuketown = {
      enable = true;
      domain = "custom.dev";
      humanUser = "human";
      agents.bot = {
        enable = true;
        uid = 1102;
        role = "ops";
        description = "";
        packages = with pkgs; [ unstable.claude-code ];
        sudo.enable = false;
        claudeCode = {
          enable = true;
          agentName = "infra-bot";
          extraAgents = {
            helper = ''
              ---
              name: helper
              description: A helper agent
              tools: Read, Grep
              ---
              You are a helper.
            '';
          };
        };
      };
    };
  };

  # ── Evaluated Configs ─────────────────────────────────────────────

  fullCfg = evalConfig fullAgentConfig [];
  noCCCfg = evalConfig noClaudeCodeConfig [];
  customCfg = evalConfig customNamingConfig [];

  # Shorthand accessors
  adaHM = fullCfg.home-manager.users.ada;
  adaCC = adaHM.programs.claude-code;
  adaPrompt = adaCC.agents.ada-software;

  voxHM = noCCCfg.home-manager.users.vox;

  botHM = customCfg.home-manager.users.bot;
  botCC = botHM.programs.claude-code;

in {

  # ── Core Module Checks ──────────────────────────────────────────

  module-users = mkCheck "module-users" [
    (assertEq "ada user exists" fullCfg.users.users.ada.isNormalUser true)
    (assertEq "ada uid" fullCfg.users.users.ada.uid 1100)
    (assertEq "ada home" fullCfg.users.users.ada.home "/agents/ada")
    (assertEq "ada group exists" fullCfg.users.groups.ada.gid 1100)
  ];

  module-git = mkCheck "module-git" [
    (assertEq "git enabled" adaHM.programs.git.enable true)
    (assertEq "git user.name" adaHM.programs.git.settings.user.name "ada")
    (assertEq "git user.email" adaHM.programs.git.settings.user.email "ada@nuketown.test")
    (assertEq "git signing" adaHM.programs.git.signing.signByDefault true)
  ];

  module-identity-toml = mkCheck "module-identity-toml" (let
    toml = adaHM.xdg.configFile."nuketown/identity.toml".text;
  in [
    (assertContains "toml has name" toml ''name = "ada"'')
    (assertContains "toml has role" toml ''role = "software"'')
    (assertContains "toml has domain" toml ''domain = "nuketown.test"'')
    (assertContains "toml has description" toml "Test software agent")
  ]);

  module-sudo = mkCheck "module-sudo" (let
    rules = fullCfg.security.sudo.extraRules;
    adaRule = builtins.head (builtins.filter (r: builtins.elem "ada" r.users) rules);
  in [
    # sudo shim is in packages (it's a derivation, just check the list is non-empty
    # and PATH override is set)
    (assertContains "PATH override for sudo shim"
      adaHM.programs.bash.sessionVariables.PATH
      "/etc/profiles/per-user/ada/bin")
    (assertEq "sudo rule user" adaRule.users [ "ada" ])
    (assertContains "sudo rule command"
      (builtins.head adaRule.commands).command
      "sudo-with-approval")
  ]);

  module-udev = mkCheck "module-udev" (let
    rules = fullCfg.services.udev.extraRules;
  in [
    (assertContains "tty rule has ATTRS" rules "ATTRS{idVendor}")
    (assertContains "tty rule has agent" rules "u:ada:rw")
    (assertContains "usb rule has ATTR" rules ''ATTR{product}=="STM32  BOOTLOADER"'')
  ]);

  module-persistence = mkCheck "module-persistence" (let
    adaPersist = fullCfg.environment.persistence."/persist".users.ada.directories;
    dirNames = map (d: d.directory) adaPersist;
  in [
    (assertEq "persist projects" (builtins.elem "projects" dirNames) true)
    (assertEq "persist claude config" (builtins.elem ".config/claude" dirNames) true)
  ]);

  module-tmpfiles = mkCheck "module-tmpfiles" (let
    rules = fullCfg.systemd.tmpfiles.rules;
    hasApprovalDir = builtins.any (r: nixpkgs.lib.hasInfix "sudo-approval" r) rules;
  in [
    (assertEq "tmpfiles has approval dir" hasApprovalDir true)
  ]);

  # ── Claude Code Integration Checks ─────────────────────────────

  claude-code-enabled = mkCheck "claude-code-enabled" [
    (assertEq "programs.claude-code.enable" adaCC.enable true)
    (assertEq "settings.permissions.defaultMode"
      adaCC.settings.permissions.defaultMode "allowEdits")
  ];

  claude-code-agent-prompt-frontmatter = mkCheck "claude-code-agent-prompt-frontmatter" [
    (assertContains "frontmatter name" adaPrompt "name: ada-software")
    (assertContains "frontmatter description" adaPrompt "software agent on")
    (assertContains "frontmatter tools" adaPrompt "tools: Read, Edit, Write, Bash, Glob, Grep")
    (assertContains "frontmatter delimiters" adaPrompt "---")
  ];

  claude-code-agent-prompt-identity = mkCheck "claude-code-agent-prompt-identity" [
    (assertContains "identity role" adaPrompt "**Role**: software")
    (assertContains "identity email" adaPrompt "ada@nuketown.test")
    (assertContains "identity git signing" adaPrompt "Commits signed with GPG")
    (assertContains "agent uid" adaPrompt "uid 1100")
    (assertContains "agent username" adaPrompt "Unix user `ada`")
  ];

  claude-code-agent-prompt-description = mkCheck "claude-code-agent-prompt-description" [
    (assertContains "description section" adaPrompt "## About You")
    (assertContains "description text" adaPrompt "Test software agent")
  ];

  claude-code-agent-prompt-environment = mkCheck "claude-code-agent-prompt-environment" [
    (assertContains "home path" adaPrompt "`/agents/ada`")
    (assertContains "ephemeral note" adaPrompt "ephemeral")
    (assertContains "persist projects" adaPrompt "`projects`")
    (assertContains "persist claude" adaPrompt "`.config/claude`")
    (assertContains "rebuilt from nix" adaPrompt "rebuilt from nix")
  ];

  claude-code-agent-prompt-sudo = mkCheck "claude-code-agent-prompt-sudo" [
    (assertContains "sudo heading" adaPrompt "## Sudo")
    (assertContains "sudo approval daemon" adaPrompt "approval daemon")
    (assertContains "sudo no password" adaPrompt "You never have a")
    (assertContains "sudo interactive approval" adaPrompt "interactive approval")
  ];

  claude-code-agent-prompt-devices = mkCheck "claude-code-agent-prompt-devices" [
    (assertContains "hardware heading" adaPrompt "## Hardware Access")
    (assertContains "tty device" adaPrompt "**tty**")
    (assertContains "vendor id" adaPrompt "idVendor=0483")
    (assertContains "product id" adaPrompt "idProduct=5740")
    (assertContains "stm32 device" adaPrompt "STM32  BOOTLOADER")
  ];

  claude-code-agent-prompt-extra = mkCheck "claude-code-agent-prompt-extra" [
    (assertContains "custom section heading" adaPrompt "## Custom Section")
    (assertContains "custom instruction" adaPrompt "This is a custom instruction")
  ];

  # ── Disabled Claude Code ────────────────────────────────────────

  claude-code-disabled = mkCheck "claude-code-disabled" [
    (assertEq "vox claude-code disabled" voxHM.programs.claude-code.enable false)
    (assertEq "vox agents empty" voxHM.programs.claude-code.agents {})
  ];

  # ── No Sudo / No Devices in Prompt ─────────────────────────────

  claude-code-no-sudo-no-devices = mkCheck "claude-code-no-sudo-no-devices" (let
    botPrompt = botCC.agents.infra-bot;
  in [
    (assertNotContains "no sudo section" botPrompt "## Sudo")
    (assertNotContains "no hardware section" botPrompt "## Hardware Access")
  ]);

  # ── Custom Agent Name ──────────────────────────────────────────

  claude-code-custom-name = mkCheck "claude-code-custom-name" [
    (assertEq "custom agent name exists" (builtins.hasAttr "infra-bot" botCC.agents) true)
    (assertContains "custom name in frontmatter" botCC.agents.infra-bot "name: infra-bot")
  ];

  # ── Extra Agents ───────────────────────────────────────────────

  claude-code-extra-agents = mkCheck "claude-code-extra-agents" [
    (assertEq "extra agent exists" (builtins.hasAttr "helper" botCC.agents) true)
    (assertContains "extra agent content" botCC.agents.helper "You are a helper")
  ];

  # ── No Description ─────────────────────────────────────────────

  claude-code-no-description = mkCheck "claude-code-no-description" (let
    botPrompt = botCC.agents.infra-bot;
  in [
    (assertNotContains "no about section" botPrompt "## About You")
  ]);

}
