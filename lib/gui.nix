# Shared pieces of programs.nicos-gui, so the NixOS and Home Manager modules
# expose the same surface instead of drifting apart.
{ lib }:
let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    literalExpression
    ;
in
rec {
  serverType = types.submodule {
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
        description = "User name to pre-fill in the connection dialog.";
      };
      tunnel = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "me@gateway.example.org";
        description = "Passed to `-t`, to reach the daemon through an SSH tunnel.";
      };
    };
  };

  # The option set both modules share.
  options = {
    enable = mkEnableOption "the NICOS Qt client";

    setupPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      example = literalExpression "with pkgs.nicosSetupPackages; [ mgml demo ]";
      description = ''
        Setup packages available to the GUI. It reads
        {file}`<setupPackage>/<instrument>/guiconfig.py`, and its instrument
        chooser globs every `nicos_*/**/guiconfig.py` under the root, so one
        client can serve several instruments.
      '';
    };

    setupPackage = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "nicos_mgml";
      description = "`setup_package`. Leave null to get the instrument chooser dialog.";
    };

    instrument = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "twenty";
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
        A {file}`guiconfig.py` passed with `-c`, bypassing
        {option}`setupPackage`/{option}`instrument` resolution entirely.
      '';
    };

    servers = mkOption {
      type = types.attrsOf serverType;
      default = { };
      example = literalExpression ''{ "twenty" = { host = "nicosbox.mgml.eu"; }; }'';
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

  # The package both modules build from their options.
  mkPackage =
    { nicosLib, cfg }:
    nicosLib.mkNicos {
      pname = "nicos-gui";
      inherit (cfg) setupPackages extraPythonPackages;
      extras = [ "gui" ] ++ cfg.extras;
      settings =
        lib.optionalAttrs (cfg.setupPackage != null) { setup_package = cfg.setupPackage; }
        // lib.optionalAttrs (cfg.instrument != null) { instrument = cfg.instrument; };
      mainProgram = "nicos-gui";
    };

  # The command line for one server entry.
  execFor =
    { cfg, server }:
    lib.concatStringsSep " " (
      [ "${cfg.finalPackage}/bin/nicos-gui" ]
      ++ lib.optionals (cfg.guiConfig != null) [
        "-c"
        "${cfg.guiConfig}"
      ]
      ++ lib.optionals (server.tunnel != null) [
        "-t"
        server.tunnel
      ]
      ++ [
        "${
          lib.optionalString (server.user != null) "${server.user}@"
        }${server.host}:${toString server.port}"
      ]
    );

  # Fires when the GUI would open its chooser on every start.
  noTargetWarning =
    cfg:
    lib.optional (cfg.servers == { } && cfg.guiConfig == null && cfg.setupPackage == null) (
      "programs.nicos-gui: no setupPackage, guiConfig or servers configured, so the GUI "
      + "will open its instrument chooser on every start."
    );
}
