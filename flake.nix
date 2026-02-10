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

              # Minimal graphical environment for testing approval dialogs
              services.xserver = {
                enable = true;
                desktopManager.xterm.enable = true;
                displayManager.lightdm = {
                  enable = true;
                  greeter.enable = false;
                };
              };

              services.displayManager.autoLogin = {
                enable = true;
                user = "human";
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
            ];

            shellHook = ''
              echo "🤘 Nuketown Development Shell"
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

            # Helper scripts
            BUILD_TEST_VM = pkgs.writeShellScriptBin "build-test-vm" ''
              VM_NAME=''${1:-basic}
              echo "Building test VM: $VM_NAME"
              nix build ".#nixosConfigurations.test-$VM_NAME.config.system.build.vm" "$@"
            '';

            RUN_TEST_VM = pkgs.writeShellScriptBin "run-test-vm" ''
              VM_NAME=''${1:-basic}
              echo "Building and running test VM: $VM_NAME"
              nix run ".#nixosConfigurations.test-$VM_NAME.config.system.build.vm"
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
              };
            };
          };

          extraConfig = { ... }: {
            # Enable approval daemon for human user
            home-manager.users.human = {
              imports = [ ./approval-daemon.nix ];

              home.stateVersion = "25.11";
              nuketown.approvalDaemon.enable = true;
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
            home-manager.users.human = {
              imports = [ ./approval-daemon.nix ];
              home.stateVersion = "25.11";
              nuketown.approvalDaemon.enable = true;
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
              };
            };
          };

          extraConfig = { ... }: {
            home-manager.users.human = {
              imports = [ ./approval-daemon.nix ];
              home.stateVersion = "25.11";
              nuketown.approvalDaemon.enable = true;
            };
          };
        };
      };

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
