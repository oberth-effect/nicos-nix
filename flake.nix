{
  description = "NICOS, the MLZ networked instrument control system, packaged for Nix and NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    # Only so that `checks.hm-gui` can type-check home/default.nix. Nothing in
    # packages/ or nixosModules/ depends on it.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nicos-src = {
      url = "github:mlz-ictrl/nicos";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      nixpkgs,
      nicos-src,
      home-manager,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      flake = {
        overlays.default = import ./pkgs/overlay.nix { inherit nicos-src; };

        # Overlay-free, for consumers who set nixpkgs.pkgs externally (a
        # module touching nixpkgs.overlays would be an eval error for them).
        nixosModules.nicos = ./nixos;
        nixosModules.default = {
          imports = [ self.nixosModules.nicos ];
          nixpkgs.overlays = [ self.overlays.default ];
        };

        homeManagerModules.nicos-gui = ./home;
        homeManagerModules.default = self.homeManagerModules.nicos-gui;

        lib = import ./lib/services.nix { inherit (nixpkgs) lib; } // {
          # Build the nicos-nix Python package set on an interpreter other than
          # the pinned python313, e.g. to try a newer one:
          #   nicos-nix.lib.nicosFor pkgs pkgs.python314
          # The 3.9 lower bound stays a hard error (NICOS enforces it itself);
          # going above 3.13 only warns.
          nicosFor = pkgs: basePython: import ./nix/python.nix { inherit pkgs basePython; };
        };
      };

      perSystem =
        { system, ... }:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ self.overlays.default ];
          };
        in
        {
          # flake-parts' own `pkgs` for this system, with our overlay applied.
          _module.args.pkgs = pkgs;

          packages = {
            default = pkgs.nicos;
            inherit (pkgs)
              nicos
              nicos-gui
              nicos-unwrapped
              gr-framework
              ;

            # The dependencies nixpkgs lacks; everything gates on these.
            lttb = pkgs.nicosPython.pkgs.lttb;
            nicos-pyctl = pkgs.nicosPython.pkgs.nicos-pyctl;
            gr = pkgs.nicosPython.pkgs.gr;
            mlzlog = pkgs.nicosPython.pkgs.mlzlog;
            frappy-core = pkgs.nicosPython.pkgs.frappy-core;
          };

          apps = {
            # `nix run` with no attribute: the GUI is the thing a person
            # actually wants to run interactively.
            default.program = "${pkgs.nicos-gui}/bin/nicos-gui";
            nicos-gui.program = "${pkgs.nicos-gui}/bin/nicos-gui";
            # The text client, for talking to an existing daemon.
            nicos-client.program = "${pkgs.nicos}/bin/nicos-client";
            # A single-process demo instrument: no cache or daemon needed.
            demo.program = "${pkgs.nicos}/bin/nicos-aio";
          };

          checks = {
            python-imports = pkgs.callPackage ./checks/python-imports.nix { };
            import-sweep = pkgs.callPackage ./checks/import-sweep.nix { };

            # Every vendored setup package builds: catches a facility tree whose
            # layout does not match `subdir`.
            setup-packages = pkgs.linkFarmFromDrvs "nicos-setup-packages" (
              nixpkgs.lib.attrValues pkgs.nicosSetupPackages
            );

            eval = pkgs.callPackage ./tests/eval.nix { inherit self nixpkgs; };
            mutable-root = pkgs.callPackage ./checks/mutable-root.nix { };

            gui-offscreen = pkgs.callPackage ./checks/gui-offscreen.nix { };

            vm-demo = pkgs.callPackage ./tests/demo.nix { inherit self; };

            # home/default.nix would otherwise never be type-checked.
            hm-gui = pkgs.callPackage ./tests/hm-gui.nix {
              inherit self home-manager;
            };
          };

          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.nicos.passthru.pythonEnv
              pkgs.nixfmt
            ];
            shellHook = ''
              echo "nicos-nix dev shell -- $(python3 --version 2>&1)"
              echo "a NICOS checkout's ./bin/nicos-aio will use this interpreter"
            '';
          };

          formatter = pkgs.nixfmt;
        };
    };
}
