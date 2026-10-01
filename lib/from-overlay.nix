# `pkgs.<attr>` with a diagnosis instead of "attribute 'nicosLib' missing".
#
# Every module in this repo needs the nicos-nix overlay, and two of its entry
# points deliberately do not apply it themselves: nixosModules.nicos (for
# consumers who set nixpkgs.pkgs externally) and the Home Manager module
# (which must not touch nixpkgs.overlays). This turns the resulting attribute
# error into something that says what to do. Needs nothing, not even `lib`.
pkgs: attr:
pkgs.${attr} or (throw ''
  nicos-nix: pkgs.${attr} is missing, so nicos-nix.overlays.default is not
  applied to this package set.
    NixOS:        import nicos-nix.nixosModules.default (it adds the overlay),
                  or add the overlay to nixpkgs.overlays yourself.
    Home Manager: add the overlay to nixpkgs.overlays in your Home Manager
                  configuration, or to the `pkgs` you pass to
                  homeManagerConfiguration.
'')
