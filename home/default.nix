# programs.nicos-gui for Home Manager.
#
# The natural place for the Qt client: it is per-user software, it keeps its
# state in ~/.config/nicos, and a workstation usually wants a different set of
# setup packages from any single instrument.
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
    mkIf
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
        chooser globs every `nicos_*/**/guiconfig.py` in the root, so one
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

    guiConfig = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        A {file}`guiconfig.py` to pass with `-c`, bypassing
        {option}`programs.nicos-gui.setupPackage` resolution entirely.
      '';
    };

    servers = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            host = mkOption {
              type = types.str;
              description = "Daemon host.";
            };
            port = mkOption {
              type = types.port;
              default = 1301;
              description = "Daemon port.";
            };
            user = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "User name to pre-fill.";
            };
            tunnel = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "me@gateway.example.org";
              description = "Passed to `-t`, to reach the daemon through an SSH tunnel.";
            };
          };
        }
      );
      default = { };
      example = literalExpression ''{ "20t" = { host = "nicosbox.mgml.eu"; }; }'';
      description = ''
        Desktop entries to generate, one per instrument, each launching the GUI
        against that daemon.
      '';
    };

    finalPackage = mkOption {
      type = types.package;
      readOnly = true;
      description = "The assembled, Qt-wrapped GUI package.";
    };
  };

  config = mkIf cfg.enable {
    programs.nicos-gui.finalPackage = pkgs.nicosLib.mkNicos {
      pname = "nicos-gui";
      inherit (cfg) setupPackages extraPythonPackages;
      extras = [ "gui" ] ++ cfg.extras;
      settings =
        lib.optionalAttrs (cfg.setupPackage != null) { setup_package = cfg.setupPackage; }
        // lib.optionalAttrs (cfg.instrument != null) { instrument = cfg.instrument; };
      mainProgram = "nicos-gui";
    };

    home.packages = [ cfg.finalPackage ];

    xdg.desktopEntries = lib.mapAttrs' (
      name: s:
      lib.nameValuePair "nicos-gui-${name}" {
        name = "NICOS (${name})";
        genericName = "Instrument control client";
        categories = [
          "Science"
          "Utility"
        ];
        exec = lib.concatStringsSep " " (
          [ "${cfg.finalPackage}/bin/nicos-gui" ]
          ++ lib.optionals (cfg.guiConfig != null) [
            "-c"
            "${cfg.guiConfig}"
          ]
          ++ lib.optionals (s.tunnel != null) [
            "-t"
            s.tunnel
          ]
          ++ [ "${lib.optionalString (s.user != null) "${s.user}@"}${s.host}:${toString s.port}" ]
        );
      }
    ) cfg.servers;

    # Note: the GUI keeps its own state in ~/.config/nicos (logs, style.qss, the
    # instrument chosen in the picker). Home Manager does not manage that, and
    # users reasonably expect it to -- say so rather than let them find out.
    warnings = lib.optional (cfg.servers == { } && cfg.guiConfig == null && cfg.setupPackage == null) (
      "programs.nicos-gui: no setupPackage, guiConfig or servers configured, so the GUI will "
      + "open its instrument chooser on every start."
    );
  };
}
