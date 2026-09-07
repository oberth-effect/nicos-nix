# programs.nicos-gui for Home Manager.
#
# The natural place for the Qt client: it is per-user software, it keeps its
# state in ~/.config/nicos, and a workstation usually wants a different set of
# setup packages from any single instrument.
#
# The option set and the package come from lib/gui.nix, shared with the NixOS
# module so the two cannot drift apart.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  guiLib = import ../lib/gui.nix { inherit lib; };
  cfg = config.programs.nicos-gui;
in
{
  options.programs.nicos-gui = guiLib.options;

  config = lib.mkIf cfg.enable {
    programs.nicos-gui.finalPackage = guiLib.mkPackage {
      inherit (pkgs) nicosLib;
      inherit cfg;
    };

    home.packages = [ cfg.finalPackage ];

    xdg.desktopEntries = lib.mapAttrs' (
      name: server:
      lib.nameValuePair "nicos-gui-${name}" {
        name = "NICOS (${name})";
        genericName = "Instrument control client";
        exec = guiLib.execFor { inherit cfg server; };
        categories = [
          "Science"
          "Utility"
        ];
      }
    ) cfg.servers;

    # Note: the GUI keeps its own state in ~/.config/nicos (its log,
    # style.qss, and the instrument chosen in the picker). Home Manager does
    # not manage that, and users reasonably expect it to.
    warnings = guiLib.noTargetWarning cfg;
  };
}
