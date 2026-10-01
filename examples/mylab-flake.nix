# A flake.nix for a repository that *is* a setup package: the lab's
# nicos_mylab tree with this file next to it. Copy it to that repository's
# root as flake.nix and adjust the names.
#
#   nicos_mylab/            __init__.py, devices/, 20t/, troja/, ...
#   hosts/nicosbox.nix      the instrument host's hardware-configuration,
#                           networking, users, system.stateVersion
#   flake.nix               this file
#
# It exposes the package, a GUI for it, a setup check, the NixOS and Home
# Manager wiring, and the instrument host itself, so that
#
#   nix build                                  builds and validates the package
#   nix run                                    opens the GUI for this instrument
#   nix flake check                            runs upstream's setup checker
#   nixos-rebuild switch --flake .#nicosbox    deploys the instrument host
#
# all work from the setup repository. A deployment flake elsewhere can take
# this repository as a normal flake input and use its overlay or modules,
# instead of the `flake = false` pattern in the README.
{
  description = "nicos_mylab: NICOS setups and device classes for MyLab";

  inputs = {
    nicos-nix.url = "github:<you>/nicos-nix";
    # One nixpkgs for everything: the NICOS interpreter and this package must
    # agree, and the host should not carry two package sets.
    nixpkgs.follows = "nicos-nix/nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nicos-nix,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAll =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              overlays = [ self.overlays.default ];
            }
          )
        );
    in
    {
      # nicos-nix's overlay composed with ours, so consumers apply just this
      # one. Without nicos-nix's first, `prev.nicosSetupPackages` would not
      # exist.
      overlays.default = nixpkgs.lib.composeManyExtensions [
        nicos-nix.overlays.default
        (final: prev: {
          # To run this instrument on another NICOS than nicos-nix's default,
          # pin it here, from a `flake = false` input at a tag (see the
          # README, "Pinning NICOS"):
          #   nicosSource = nicos-src;
          #   nicosVersion = "3.13.2";

          nicosSetupPackages = prev.nicosSetupPackages // {
            mylab = final.nicosLib.mkSetupPackage {
              name = "nicos_mylab"; # the importable name, i.e. setup_package
              src = self;
              subdir = "nicos_mylab"; # where it sits in this repository
              version = "0-unstable-${self.shortRev or "dirty"}";
              # What nicos_mylab/devices/*.py import. Keep hardware bindings
              # here rather than in services.nicos.extraPythonPackages: they
              # then travel with the package to the services, the GUI and the
              # setup checker alike.
              pythonDeps = ps: [ ps.pyserial ];
            };
          };
        })
      ];

      # Wiring only. The host enables the services and picks instrument,
      # directories and service list, because those differ per machine.
      nixosModules.default =
        { pkgs, ... }:
        {
          imports = [ nicos-nix.nixosModules.nicos ]; # the overlay-free variant
          nixpkgs.overlays = [ self.overlays.default ];
          services.nicos = {
            setupPackages = [ pkgs.nicosSetupPackages.mylab ];
            setupPackage = "nicos_mylab";
          };
        };

      # Workstations: the GUI knowing this instrument, one desktop entry per
      # daemon. `nixpkgs.overlays` is a standalone Home Manager option; under
      # the NixOS Home Manager module with useGlobalPkgs, apply the overlay
      # system-wide instead.
      homeManagerModules.default =
        { pkgs, ... }:
        {
          imports = [ nicos-nix.homeManagerModules.default ];
          nixpkgs.overlays = [ self.overlays.default ];
          programs.nicos-gui = {
            setupPackages = [ pkgs.nicosSetupPackages.mylab ];
            setupPackage = "nicos_mylab";
            servers."20t" = {
              host = "nicosbox.example.org";
            };
          };
        };

      packages = forAll (pkgs: rec {
        # `nix build`: the package alone. Fails on a missing __init__.py or a
        # device module that does not compile.
        default = pkgs.nicosSetupPackages.mylab;

        # A GUI that knows only this instrument.
        nicos-gui = pkgs.nicosLib.mkNicos {
          pname = "nicos-gui-mylab";
          extras = [ "gui" ];
          setupPackages = [ default ];
          settings = {
            setup_package = "nicos_mylab";
            instrument = "20t";
            # The GUI writes neither, but left relative they would resolve
            # against the read-only store root.
            pid_path = "/tmp/nicos-mylab/pid";
            logging_path = "/tmp/nicos-mylab/log";
          };
          mainProgram = "nicos-gui";
        };
      });

      # `nix run` with no attribute opens the GUI; packages.default is the
      # setup package, which has nothing to run.
      apps = forAll (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.nicos-gui}/bin/nicos-gui";
          meta.description = "The NICOS Qt client for MyLab";
        };
      });

      checks = forAll (
        pkgs:
        let
          # A headless composition of what the instrument runs, for the
          # checker to look at.
          nicos = pkgs.nicosLib.mkNicos {
            setupPackages = [ pkgs.nicosSetupPackages.mylab ];
            settings = {
              setup_package = "nicos_mylab";
              instrument = "20t";
              setup_subdirs = [
                "20t"
                "troja"
              ];
              pid_path = "/tmp/nicos-mylab/pid";
              logging_path = "/tmp/nicos-mylab/log";
            };
          };
        in
        {
          # Every special setup the services need exists, and with "full"
          # device classes, parameters and guiconfig.py validate too. "full"
          # pulls Qt and GR into the build closure; use "names" if that is too
          # heavy for your CI.
          setups = pkgs.nicosLib.checkSetups {
            inherit nicos;
            setupNames = [
              "cache"
              "poller"
              "daemon"
              "elog"
              "watchdog"
              "monitor-html"
            ];
            level = "full";
          };
        }
      );

      # The instrument host, so `nixos-rebuild switch --flake .#nicosbox`
      # works from this repository.
      nixosConfigurations.nicosbox = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          self.nixosModules.default
          ./hosts/nicosbox.nix
          {
            services.nicos = {
              enable = true;
              instrument = "20t";
              setupSubdirs = [
                "20t"
                "troja"
              ];
              services = [
                "cache"
                "poller"
                "daemon"
                "elog"
                "watchdog"
                "monitor-html"
              ];
              extras = [
                "tango"
                "keyring"
              ];
              logDir = "/data/log";
              pidDir = "/data/pid";
              dataDir = "/data";
              openFirewall = true;
            };
          }
        ];
      };
    };
}
