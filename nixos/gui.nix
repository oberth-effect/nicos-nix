# programs.nicos-gui for NixOS.
#
# Separate from services.nicos on purpose: a GUI root pulls Qt and GR into the
# closure, which has no business on a headless instrument control box. A
# machine running both can point one at the other's setup packages.
#
# The option set and the package come from lib/gui.nix, shared with the Home
# Manager module so the two cannot drift apart.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  guiLib = import ../lib/gui.nix { inherit lib; };
  fromOverlay = import ../lib/from-overlay.nix;
  cfg = config.programs.nicos-gui;
in
{
  options.programs.nicos-gui = guiLib.options;

  config = lib.mkIf cfg.enable {
    programs.nicos-gui.finalPackage = guiLib.mkPackage {
      nicosLib = fromOverlay pkgs "nicosLib";
      inherit cfg;
    };

    environment.systemPackages = [
      cfg.finalPackage
    ]
    ++ lib.mapAttrsToList (
      name: server:
      pkgs.makeDesktopItem {
        name = "nicos-gui-${name}";
        desktopName = "NICOS (${name})";
        genericName = "Instrument control client";
        exec = guiLib.execFor { inherit cfg server; };
        categories = [
          "Science"
          "Utility"
        ];
      }
    ) cfg.servers;

    warnings = guiLib.warningsFor cfg;
  };
}
