{
  description = "Nuketown - AI agents as Unix users";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    impermanence = {
      url = "github:nix-community/impermanence";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, home-manager, impermanence, sops-nix }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      # Helper to create test VMs with nuketown
      mkTestVM = { name, system ? "x86_64-linux", agentConfig ? {}, extraConfig ? {} }:
        nixpkgs.lib.nixosSystem {
          inherit system;

          modules = [
            # Nuketown module
            ./module.nix

            # Home-manager integration
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
            }

            # Impermanence for testing ephemeral homes
            impermanence.nixosModules.impermanence

            # Sops for secret management
            sops-nix.nixosModules.sops

            # Make unstable packages available
            ({ config, ... }: {
              nixpkgs.overlays = [
                (final: prev: {
                  unstable = import nixpkgs-unstable {
                    inherit system;
                    config.allowUnfree = true;
                  };
                })
              ];
            })

            # Base VM configuration
            ({ config, pkgs, ... }: {
              system.stateVersion = "25.11";

              # Enable flakes
              nix.settings.experimental-features = [ "nix-command" "flakes" ];

              # Boot configuration for VMs
              boot.loader.grub.device = "/dev/vda";
              fileSystems."/" = {
                device = "/dev/vda1";
                fsType = "ext4";
              };

              # Test user (the "human")
              users.mutableUsers = false;
              users.users.human = {
                uid = 1000;
                isNormalUser = true;
                extraGroups = [ "wheel" ];
                password = "test";
              };

              security.sudo.wheelNeedsPassword = false;

              # Enable SSH for remote access
              services.openssh = {
                enable = true;
                settings.PermitRootLogin = "no";
                settings.PasswordAuthentication = true;
                # Limit pubkey attempts to avoid "too many authentication failures"
                settings.PubkeyAuthentication = false;
              };

              # Enable VM guest additions
              virtualisation.vmVariant = {
                virtualisation = {
                  memorySize = 2048;
                  cores = 2;
                  diskSize = 8192;
                  forwardPorts = [
                    { from = "host"; host.port = 2222; guest.port = 22; }
                  ];
                };
              };

              # Base packages
              environment.systemPackages = with pkgs; [
                vim
                git
                htop
                tmux
              ];
            })

            # Nuketown configuration
            agentConfig

            # Extra user configuration
            extraConfig
          ];
        };

    in {
      # Export the nuketown module for use in other flakes
      nixosModules = {
        default = ./module.nix;
        nuketown = ./module.nix;
        approvalDaemon = ./approval-daemon.nix;  # backwards compat alias
      };

      # Home-manager modules (for the human's config)
      homeManagerModules = {
        approvalDaemon = ./approval-daemon.nix;
      };

      # Development shell
      devShells = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in {
          default = pkgs.mkShell {
            name = "nuketown-dev";

            packages = with pkgs; [
              # Nix tools
              nixos-rebuild
              nix-tree
              nvd

              # Testing tools
              qemu

              # Development utilities
              git
              ripgrep
              fd
              jq

              # Documentation
              mdbook

              # Helper scripts
              (writeShellScriptBin "build-test-vm" ''
                VM_NAME=''${1:-basic}
                echo "Building test VM: $VM_NAME"
                nix build ".#nixosConfigurations.test-$VM_NAME.config.system.build.vm"
              '')
              (writeShellScriptBin "run-test-vm" ''
                VM_NAME=''${1:-basic}
                echo "Building and running test VM: $VM_NAME"
                nix run ".#nixosConfigurations.test-$VM_NAME.config.system.build.vm"
              '')
            ];

            shellHook = ''
              echo "Nuketown Development Shell"
              echo ""
              echo "Available commands:"
              echo "  build-test-vm    - Build a test VM"
              echo "  run-test-vm      - Build and run a test VM"
              echo ""
              echo "Test VMs available:"
              echo "  - basic: Minimal nuketown setup with one agent"
              echo "  - multi: Multiple agents with different roles"
              echo "  - hardware: Agent with hardware device access"
              echo ""
            '';
          };
        }
      );

      # Test VM configurations
      nixosConfigurations = {
        # Basic test VM with one agent
        test-basic = mkTestVM {
          name = "test-basic";
          agentConfig = { pkgs, ... }: {
            nuketown = {
              enable = true;
              domain = "nuketown.test";
              humanUser = "human";

              agents.ada = {
                enable = true;
                uid = 1100;
                role = "software";
                description = "Test software agent";

                packages = with pkgs; [
                  unstable.claude-code
                ];

                persist = [ "projects" ];

                sudo.enable = true;
                portal.enable = true;

                claudeCode = {
                  enable = true;
                  settings.permissions.defaultMode = "allowEdits";
                };
              };
            };
          };

          extraConfig = { ... }: {
            # Enable mock approval for automated testing
            systemd.tmpfiles.rules = [
              "f /run/sudo-approval/mode 0644 human users - MOCK_APPROVED"
            ];

            home-manager.users.human = {
              home.stateVersion = "25.11";
            };
          };
        };

        # Multi-agent test VM
        test-multi = mkTestVM {
          name = "test-multi";
          agentConfig = { pkgs, ... }: {
            nuketown = {
              enable = true;
              domain = "nuketown.test";
              humanUser = "human";

              agents.ada = {
                enable = true;
                uid = 1100;
                role = "software";
                description = "Software development agent";
                packages = with pkgs; [ unstable.claude-code gcc ];
                persist = [ "projects" ];
                sudo.enable = true;
                portal.enable = true;
              };

              agents.vox = {
                enable = true;
                uid = 1101;
                role = "research";
                description = "Research and documentation agent";
                packages = with pkgs; [ unstable.claude-code python3 ];
                persist = [ "projects" "notes" ];
                portal.enable = true;
              };

              agents.ops = {
                enable = true;
                uid = 1102;
                role = "operations";
                description = "System operations agent";
                packages = with pkgs; [ unstable.claude-code kubectl ];
                persist = [ "projects" ];
                sudo.enable = true;
              };
            };
          };

          extraConfig = { ... }: {
            # Enable mock approval for automated testing
            systemd.tmpfiles.rules = [
              "f /run/sudo-approval/mode 0644 human users - MOCK_APPROVED"
            ];

            home-manager.users.human = {
              home.stateVersion = "25.11";
            };
          };
        };

        # Hardware access test VM
        test-hardware = mkTestVM {
          name = "test-hardware";
          agentConfig = { pkgs, ... }: {
            nuketown = {
              enable = true;
              domain = "nuketown.test";
              humanUser = "human";

              agents.ada = {
                enable = true;
                uid = 1100;
                role = "hardware";
                description = "Hardware development agent";

                packages = with pkgs; [
                  unstable.claude-code
                  gcc-arm-embedded
                  openocd
                ];

                persist = [ "projects" ];
                sudo.enable = true;
                portal.enable = true;

                # Example device access rules
                devices = [
                  {
                    subsystem = "tty";
                    attrs = { idVendor = "0483"; idProduct = "5740"; };
                  }
                ];

                claudeCode = {
                  enable = true;
                  settings.permissions.defaultMode = "allowEdits";
                };
              };
            };
          };

          extraConfig = { ... }: {
            # Enable mock approval for automated testing
            systemd.tmpfiles.rules = [
              "f /run/sudo-approval/mode 0644 human users - MOCK_APPROVED"
            ];

            home-manager.users.human = {
              home.stateVersion = "25.11";
            };
          };
        };
      };

      # Testing apps
      apps = forAllSystems (system:
        let
          pkgs = pkgsFor system;

          # Package all test files together
          testPackage = pkgs.runCommand "nuketown-tests" {} ''
            mkdir -p $out/tests
            cp ${./tests}/*.sh $out/tests/
            chmod +x $out/tests/*.sh
          '';

          # Test runner with all dependencies in scope
          testRunner = pkgs.writeScript "nuketown-test" ''
            #!${pkgs.bash}/bin/bash
            export PATH="${pkgs.lib.makeBinPath [ pkgs.sshpass pkgs.coreutils pkgs.findutils pkgs.gnused pkgs.gnugrep pkgs.openssh ]}:$PATH"
            exec ${pkgs.bash}/bin/bash ${testPackage}/tests/run-tests.sh "$@"
          '';

          # VM manager with dependencies
          vmManager = pkgs.writeScript "nuketown-vm" ''
            #!${pkgs.bash}/bin/bash
            export PATH="${pkgs.lib.makeBinPath [ pkgs.sshpass pkgs.coreutils pkgs.findutils pkgs.gnused pkgs.gnugrep pkgs.openssh pkgs.qemu ]}:$PATH"
            export NUKETOWN_TEST_RUNNER="${testRunner}"
            exec ${pkgs.bash}/bin/bash ${./vm-manager.sh} "$@"
          '';
        in {
          # Run tests
          test = {
            type = "app";
            program = toString testRunner;
          };

          # VM manager for testing
          vm = {
            type = "app";
            program = toString vmManager;
          };
        }
      );

      # ── Evaluation Checks ─────────────────────────────────────────
      # Pure nix assertions against evaluated module config.
      # No VM boot needed — instant feedback.
      #
      #   nix flake check           # run all checks
      #   nix build .#checks.x86_64-linux.claude-code-enabled  # run one
      checks = forAllSystems (system:
        import ./checks.nix {
          inherit nixpkgs nixpkgs-unstable home-manager impermanence sops-nix;
          nuketownModule = ./module.nix;
        }
      );

      # Package outputs (empty for now, but useful for future additions)
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in {
          # Could add helper packages here
        }
      );
    };
}
