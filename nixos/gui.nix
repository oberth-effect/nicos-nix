# programs.nicos-gui -- the Qt client, for workstations.
#
# Separate from services.nicos on purpose: a GUI root pulls Qt and GR into the
# closure, which has no business on a headless instrument control box. A
# machine running both can point this at the same package.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    literalExpression
    ;
  cfg = config.programs.nicos-gui;
in
{
  options.programs.nicos-gui = {
    enable = mkEnableOption "the NICOS Qt client";

    setupPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      example = literalExpression "with pkgs.nicosSetupPackages; [ demo mlz ]";
      description = ''
        Setup packages available to the GUI. It reads
        {file}`<setupPackage>/<instrument>/guiconfig.py`, and its instrument
        chooser globs every `nicos_*/**/guiconfig.py` under the root -- so one
        client can serve several instruments.
      '';
    };

    setupPackage = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "nicos_mylab";
      description = "`setup_package`. Leave null to get the instrument chooser dialog.";
    };

    instrument = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "20t";
      description = "`instrument`. Leave null to get the instrument chooser dialog.";
    };

    extras = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "tango" ];
      description = "Extra optional dependency groups, on top of `gui`.";
    };

    extraPythonPackages = mkOption {
      type = types.functionTo (types.listOf types.package);
      default = _: [ ];
      defaultText = literalExpression "ps: [ ]";
      description = "Extra Python packages for the GUI process.";
    };

    finalPackage = mkOption {
      type = types.package;
      readOnly = true;
      description = "The assembled, Qt-wrapped GUI package.";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.nicos-gui.finalPackage = pkgs.nicosLib.mkNicos {
      pname = "nicos-gui";
      setupPackages = cfg.setupPackages;
      extras = [ "gui" ] ++ cfg.extras;
      inherit (cfg) extraPythonPackages;
      settings =
        lib.optionalAttrs (cfg.setupPackage != null) { setup_package = cfg.setupPackage; }
        // lib.optionalAttrs (cfg.instrument != null) { instrument = cfg.instrument; };
      mainProgram = "nicos-gui";
    };

    environment.systemPackages = [ cfg.finalPackage ];
  };
}
