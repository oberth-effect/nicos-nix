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

    package = mkOption {
      type = types.nullOr types.package;
      default = null;
      defaultText = literalExpression "pkgs.nicos-unwrapped";
      description = ''
        The bare NICOS source tree to build the GUI from, the counterpart of
        `services.nicos.package`. `null` means `pkgs.nicos-unwrapped`; a
        machine that also runs `services.nicos` can pass
        `config.services.nicos.package` to keep both on one revision.
      '';
    };

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
      description = ''
        `setup_package`. Leave null to get the instrument chooser dialog.
        Unlike `services.nicos.setupPackage`, `null` never auto-selects a
        single entry of {option}`programs.nicos-gui.setupPackages`: the
        chooser is the point of a multi-instrument client.
      '';
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
        A {file}`guiconfig.py` passed with `-c` to the desktop entries
        generated from {option}`programs.nicos-gui.servers`, bypassing
        `setupPackage`/`instrument` resolution for those. It does not reach a
        plain `nicos-gui` run from `PATH`, which resolves through
        `setupPackage`/`instrument` as usual.
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
    nicosLib.mkNicos (
      {
        pname = "nicos-gui";
        inherit (cfg) setupPackages extraPythonPackages;
        extras = [ "gui" ] ++ cfg.extras;
        settings = {
          # The GUI is a client and writes neither pids nor service logs (its
          # own log goes to ~/.config/nicos/log), but left relative these would
          # resolve against the read-only store root. The same values as the
          # overlay's nicos-gui.
          pid_path = "/tmp/nicos-gui/pid";
          logging_path = "/tmp/nicos-gui/log";
        }
        // lib.optionalAttrs (cfg.setupPackage != null) { setup_package = cfg.setupPackage; }
        // lib.optionalAttrs (cfg.instrument != null) { instrument = cfg.instrument; };
        mainProgram = "nicos-gui";
      }
      // lib.optionalAttrs (cfg.package != null) { nicos = cfg.package; }
    );

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

  # Configurations that are legal but almost certainly not what was meant.
  warningsFor =
    cfg:
    # The GUI would open its chooser on every start.
    lib.optional (cfg.servers == { } && cfg.setupPackage == null) (
      "programs.nicos-gui: no setupPackage or servers configured, so the GUI "
      + "will open its instrument chooser on every start."
    )
    # guiConfig is only spliced into the desktop entries.
    ++ lib.optional (cfg.guiConfig != null && cfg.servers == { }) (
      "programs.nicos-gui.guiConfig only reaches the desktop entries generated from "
      + "programs.nicos-gui.servers, which is empty, so it has no effect."
    );
}
