# The NICOS NixOS module.
#
# Flat `services.nicos` today. The option set and the config generator live in
# separate files and are pure functions of (name, cfg), so adding
# `services.nicos.instances.<name>` later is additive: unit names already go
# through nlib.unitNameFor, which returns today's `nicos-cache` for the flat
# instance and `nicos-<inst>-cache` for a named one.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nicos;
  mkInstanceOptions = import ./instance-options.nix;
  mkInstanceConfig = import ./instance-config.nix;
in
{
  imports = [ ./gui.nix ];

  options.services.nicos = mkInstanceOptions { inherit lib pkgs; };

  # Later, verbatim, in ./instances.nix:
  #   options.services.nicos.instances = mkOption {
  #     type = types.attrsOf (types.submodule (_: {
  #       options = mkInstanceOptions { inherit lib pkgs; };
  #     }));
  #     default = { };
  #   };
  # and one more entry in the mkMerge below.

  config = lib.mkIf cfg.enable (mkInstanceConfig {
    inherit lib pkgs cfg;
    name = null;
  });
}
