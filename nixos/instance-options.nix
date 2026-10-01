# The option set for one NICOS instance.
#
# A plain function rather than a submodule, so the identical set can be spliced
# flat into `services.nicos` (today) or into a types.submodule at
# `services.nicos.instances.<name>` (later) with no duplication.
{ lib, pkgs }:
let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    literalExpression
    literalMD
    ;
  nlib = import ../lib/services.nix { inherit lib; };
  fromOverlay = import ../lib/from-overlay.nix;
  tomlFormat = pkgs.formats.toml { };

  serviceType = types.submodule (
    { name, config, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether to generate a systemd unit for this NICOS service.
            Disabled services are also dropped from the `services` key of the
            generated {file}`nicos.conf`.
          '';
        };

        procName = mkOption {
          type = types.enum nlib.knownProcNames;
          default = (nlib.splitServiceName name).procName;
          defaultText = literalMD "the part of the attribute name before the first `-`";
          example = "collector";
          description = ''
            Which NICOS binary to run, i.e. {file}`bin/nicos-''${procName}`.
            Derived from the attribute name, so `"collector-ppms9"` runs
            `nicos-collector`.

            There is no `nicos-monitor-html` binary: `"monitor-html"` runs
            `nicos-monitor` with {option}`setup` set to `monitor-html`.
          '';
        };

        setup = mkOption {
          type = types.nullOr types.str;
          default = if (nlib.splitServiceName name).instance == null then null else name;
          defaultText = literalMD "the full attribute name if it contains a `-`, else `null`";
          example = "collector-ppms9";
          description = ''
            The value passed to `-S`. This is a *setup name*: the service loads
            {file}`<setupPackage>/<instrument>/setups/special/''${setup}.py`.

            `null` means no `-S`, so the service loads its default special
            setup, {file}`setups/special/<procName>.py`.
          '';
        };

        extraArgs = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "-v" ];
          description = "Extra command line arguments, appended after `-D` and `-S`.";
        };

        restart = mkOption {
          type = types.enum [
            "no"
            "always"
            "on-success"
            "on-failure"
            "on-abnormal"
            "on-abort"
            "on-watchdog"
          ];
          default = if config.procName == "monitor" then "on-failure" else "on-abnormal";
          defaultText = literalMD "`on-failure` for monitors, `on-abnormal` otherwise (upstream's rule)";
          description = ''
            systemd `Restart=`. The default mirrors
            {file}`etc/nicos-late-generator`. Note that `on-abnormal`
            deliberately does not restart after a clean non-zero exit, so a
            broken setup file fails loudly instead of looping.
          '';
        };

        timeoutStartSec = mkOption {
          type = types.either types.ints.unsigned types.str;
          default = if config.procName == "poller" then 900 else 300;
          defaultText = literalMD "`900` for the poller, `300` otherwise";
          example = "infinity";
          description = ''
            systemd `TimeoutStartSec=`: how long the service may take to send
            `READY=1`.

            The poller is by far the slowest starter -- it loads every setup and
            forks a child process per setup -- so it gets a much larger default.
            Instruments with many setups, or slow hardware that is probed at
            startup, may need more still; a timeout shows up as
            `Result=timeout` in `systemctl show`, followed by a restart.

            Note that upstream's generated units set no timeout at all and so
            inherit systemd's 90 s default, which is tighter than either default
            here.
          '';
        };

        systemdProps = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "LimitRSS=2G" ];
          description = ''
            Extra `[Service]` lines for this service only, in the `Key=Value`
            syntax of the `systemd_props` key of {file}`nicos.conf`. Merged
            after {option}`services.nicos.systemdProps`.

            Prefer {option}`unit`; this exists so an existing
            {file}`nicos.conf` can be transcribed verbatim.
          '';
        };

        unit = mkOption {
          type = types.deferredModule;
          default = { };
          example = literalExpression ''
            {
              serviceConfig.Nice = -5;
              after = [ "tango.service" ];
            }
          '';
          description = ''
            Extra systemd unit configuration, merged into the generated unit.
            Accepts everything {option}`systemd.services.<name>` accepts,
            including `lib.mkForce`.

            Prefer this over writing {option}`systemd.services."nicos-cache"`
            directly: the unit name is an implementation detail that gains an
            instance prefix under `services.nicos.instances.<name>`, whereas
            this option does not.
          '';
        };
      };
    }
  );
in
{
  enable = mkEnableOption "the NICOS lab control system services";

  package = mkOption {
    type = types.package;
    default = fromOverlay pkgs "nicos-unwrapped";
    defaultText = literalExpression "pkgs.nicos-unwrapped";
    description = ''
      The bare NICOS source tree. Override to pin a different NICOS revision,
      e.g. `pkgs.nicos-unwrapped.overrideAttrs (_: { src = mySrc; })`.
      This is not what runs; see {option}`services.nicos.finalPackage`.
    '';
  };

  finalPackage = mkOption {
    type = types.package;
    readOnly = true;
    description = ''
      The complete, runnable NICOS assembled from the other options. Read-only,
      because this module assembles it. Reference it to run tools by hand, e.g.
      `''${config.services.nicos.finalPackage}/bin/nicos-keystore add ...`.
    '';
  };

  setupPackages = mkOption {
    type = types.listOf types.package;
    default = [ ];
    example = literalExpression "[ pkgs.nicosSetupPackages.demo ]";
    description = ''
      Setup packages to make available, each providing a `nicos_<facility>/`
      directory. Build them with `pkgs.nicosLib.mkSetupPackage`.

      Only one is *active* per process -- see {option}`services.nicos.setupPackage`.
      The others still matter: setups may import device classes from them, and
      the GUI's instrument chooser globs all of them.
    '';
  };

  setupPackage = mkOption {
    type = types.nullOr types.str;
    default = null;
    defaultText = literalMD "`null`: use the single entry of {option}`services.nicos.setupPackages`, if there is exactly one";
    example = "nicos_mylab";
    description = ''
      `setup_package`: the Python package name (`nicos_mylab`, not `mylab`)
      whose setups this instance uses.

      `null` selects the only entry of {option}`services.nicos.setupPackages`
      when there is exactly one, and is an error otherwise once any service is
      enabled. (This differs from `programs.nicos-gui.setupPackage`, where
      `null` means the instrument chooser.)
    '';
  };

  instrument = mkOption {
    type = types.nullOr types.str;
    default = null;
    example = "20t";
    description = ''
      `instrument`: the subdirectory of {option}`services.nicos.setupPackage`
      defining this instrument. Also the default of
      {option}`services.nicos.setupSubdirs`, and where {file}`guiconfig.py` is
      looked for.
    '';
  };

  setupSubdirs = mkOption {
    type = types.listOf types.str;
    default = [ ];
    example = [
      "20t"
      "troja"
    ];
    description = ''
      `setup_subdirs`: which subdirectories of the setup package contribute
      setups. Empty (the default) means just
      {option}`services.nicos.instrument`.
    '';
  };

  services = mkOption {
    type = types.coercedTo (types.listOf types.str) (names: lib.genAttrs names (_: { })) (
      types.attrsOf serviceType
    );
    default = { };
    example = literalExpression ''[ "cache" "poller" "daemon" "elog" "watchdog" "monitor-html" ]'';
    description = ''
      The NICOS services to run, named exactly as in the `services` key of
      {file}`nicos.conf`: either a bare name (`"cache"`) or
      `"<proc>-<instance>"` (`"collector-ppms9"`), which runs
      `nicos-<proc> -S <proc>-<instance>`.

      May be a plain list -- convenient when transcribing an existing
      {file}`nicos.conf` -- or an attribute set for per-service tuning. The two
      forms merge, either across separate modules or with `lib.mkMerge`:

      ```nix
      services.nicos.services = lib.mkMerge [
        [ "cache" "poller" "collector-ppms9" ]
        { "collector-ppms9".unit.serviceConfig.Nice = -5; }
      ];
      ```

      (Two plain assignments to `services` and `services.<name>` in the *same*
      attribute set would be a duplicate-attribute error, not a merge.)
    '';
  };

  extras = mkOption {
    type = types.listOf types.str;
    default = [ ];
    example = [
      "tango"
      "keyring"
    ];
    description = ''
      Optional dependency groups, validated against
      `pkgs.nicos-unwrapped.optional-dependencies`.

      `tango` and `secop` install *client libraries* only: those servers have
      their own lifecycle and are not managed by this module.
    '';
  };

  extraPythonPackages = mkOption {
    type = types.functionTo (types.listOf types.package);
    default = _: [ ];
    defaultText = literalExpression "ps: [ ]";
    example = literalExpression "ps: [ ps.pyserial ]";
    description = ''
      Extra Python packages for every NICOS process, for hardware bindings your
      own setup files import that no {option}`services.nicos.extras` group
      covers.
    '';
  };

  root = {
    mode = mkOption {
      type = types.enum [
        "store"
        "mutable"
      ];
      default = "store";
      description = ''
        `store` builds the NICOS root as a derivation: reproducible, and the
        running code is pinned by the flake.

        `mutable` runs from {option}`services.nicos.root.path`, a writable
        checkout this module does not manage. Use it for development, or when
        your setups use paths relative to `nicos_root` -- which is how most
        NICOS setups are written, and which cannot work against a read-only
        store path.
      '';
    };

    path = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/srv/nicos";
      description = ''
        The NICOS root when {option}`services.nicos.root.mode` is `mutable`.
        `config.nicos_root` becomes exactly this, so it must contain
        {file}`nicos/`, {file}`bin/` and your setup packages -- a NICOS
        checkout.
      '';
    };

    manageNicosConf = mkOption {
      type = types.bool;
      default = true;
      description = ''
        In `mutable` mode, symlink {file}`<path>/nicos.conf` to the file
        generated from these options, so a rebuild updates it and it cannot
        drift. Set to `false` to manage it yourself.
      '';
    };

    seed = mkOption {
      type = types.nullOr types.package;
      default = null;
      example = literalExpression "pkgs.nicos-unwrapped";
      description = ''
        In `mutable` mode, populate {option}`services.nicos.root.path` from
        this package once, if it does not yet contain
        {file}`nicos/configmod.py`, and never touch it again. `null` means the
        directory is entirely yours (a `git clone`).
      '';
    };
  };

  mutableSetupPackages = mkOption {
    type = types.listOf types.str;
    default = [ ];
    example = [ "/srv/nicos-setups" ];
    description = ''
      Directories appended to `PYTHONPATH` in the `[environment]` section of
      the generated {file}`nicos.conf`, each containing a `nicos_<facility>/`
      package.

      NICOS applies that to `sys.path` before
      `importlib.import_module(setup_package)`, so this keeps NICOS core pinned
      by Nix while letting you edit setups without a rebuild -- the
      lighter-weight alternative to `root.mode = "mutable"`.
    '';
  };

  user = mkOption {
    type = types.str;
    default = "nicos";
    description = ''
      The user the services run as, and the `user` key of {file}`nicos.conf`.
      At the default this module creates the account; otherwise it must exist.
    '';
  };

  group = mkOption {
    type = types.str;
    default = "nicos";
    description = "The group the services run as, and the `group` key of {file}`nicos.conf`.";
  };

  umask = mkOption {
    type = types.strMatching "[0-7]{3,4}";
    default = "002";
    description = ''
      systemd `UMask=` and the `umask` key of {file}`nicos.conf` (a string, not
      a number). `002` makes data files group-writable, which is usually what
      shared instrument data wants.
    '';
  };

  logDir = mkOption {
    type = types.path;
    default = "/var/log/nicos";
    example = "/data/log";
    description = ''
      `logging_path`; logs land in
      {file}`<logDir>/<service>/<service>-YYYY-MM-DD.log`.

      Always written to {file}`nicos.conf`, and must be absolute (the type
      enforces it): NICOS resolves a relative value against `nicos_root`,
      which in `store` mode is read-only.
    '';
  };

  pidDir = mkOption {
    type = types.path;
    default = "/run/nicos";
    example = "/data/pid";
    description = ''
      `pid_path`. Largely vestigial under systemd -- no PID file is written in
      `-D` mode -- but NICOS still needs the key absolute, for the reason given
      at {option}`services.nicos.logDir`.
    '';
  };

  dataDir = mkOption {
    type = types.path;
    default = "/var/lib/nicos";
    example = "/data";
    description = ''
      A writable state directory created and owned by this module, and the home
      directory of {option}`services.nicos.user`.

      NICOS does *not* learn this path from {file}`nicos.conf`: the data root
      lives in your setup files (`Exp.dataroot`,
      `FlatfileCacheDatabase.storepath`). This module creates the directory and
      exports it as `$NICOS_DATA_ROOT` so setups can pick it up via
      `os.environ`.
    '';
  };

  extraDirectories = mkOption {
    type = types.attrsOf (
      types.submodule {
        options.mode = mkOption {
          type = types.str;
          default = "0770";
          description = "Permission mode for the directory.";
        };
      }
    );
    default = { };
    example = literalExpression ''{ "/data/cache" = { }; "/data/logbook".mode = "2770"; }'';
    description = ''
      Additional directories to create, owned by
      {option}`services.nicos.user`. Typically the flat-file cache store and the
      electronic logbook directory referenced from your special setups.
    '';
  };

  keystorePaths = mkOption {
    type = types.listOf types.str;
    default = [ "/etc/nicos/keystore" ];
    description = ''
      `keystorepaths`. Upstream's default also contains
      {file}`~/.config/nicos/keystore`, dropped here because a system service
      should not depend on a per-user path.

      Each directory is created by this module, owned by
      {option}`services.nicos.user` with mode `0750`, so that
      `''${config.services.nicos.finalPackage}/bin/nicos-keystore add ...`
      run as that user can write its keyring file.
    '';
  };

  environment = mkOption {
    type = types.attrsOf types.str;
    default = { };
    example = {
      TANGO_HOST = "tangobox:10000";
    };
    description = ''
      The `[environment]` section of {file}`nicos.conf`. These become
      environment variables inside the NICOS process, with `$VAR`
      self-reference expansion.

      Because NICOS applies them at config load, they cannot influence the
      dynamic loader -- put `LD_LIBRARY_PATH` and friends in
      {option}`services.nicos.extraWrapperEnv` instead.

      A `PYTHONPATH` here is appended after
      {option}`services.nicos.mutableSetupPackages`, never in place of it.
    '';
  };

  extraWrapperEnv = mkOption {
    type = types.attrsOf types.str;
    default = { };
    example = {
      QT_QPA_PLATFORM = "offscreen";
    };
    description = "Environment variables baked into the `bin/nicos-*` wrappers, i.e. set before Python starts.";
  };

  settings = mkOption {
    type = tomlFormat.type;
    default = { };
    example = {
      sandbox_simulation = false;
    };
    description = ''
      Free-form extra keys for the `[nicos]` section of {file}`nicos.conf`.
      NICOS `setattr`s every key it finds, so arbitrary keys are legal.

      Keys owned by a dedicated option above are rejected here. Options left
      at `null` are omitted so that
      {file}`<setupPackage>/<instrument>/nicos.conf` can still supply them.
      `logging_path`, `pid_path`, `services`, `user`, `group`, `umask` and
      `keystorepaths` have defaults and are therefore always written.
    '';
  };

  systemdProps = mkOption {
    type = types.listOf types.str;
    default = [ ];
    example = [ "LimitRSS=2G" ];
    description = "`systemd_props`: extra `[Service]` lines applied to every generated unit.";
  };

  requireNetworkOnline = mkOption {
    type = types.bool;
    default = false;
    description = ''
      Whether `nicos.target` should `Requires=network-online.target`, which is
      upstream's behaviour, or merely `Wants=` it. On NixOS a failing
      `*-wait-online.service` would otherwise take the whole instrument down at
      boot, so the weaker form is the default.
    '';
  };

  checkSetups = mkOption {
    type = types.enum [
      false
      "names"
      "full"
    ];
    default = "names";
    example = "full";
    description = ''
      Validate this instance's setups at build time, so a mistake fails
      `nixos-rebuild` instead of the instrument.

      `"names"` (the default) asserts that every special setup implied by
      {option}`services.nicos.services` exists. This is cheap and adds nothing
      to the closure. It catches the failure that motivates the whole feature:
      a typo such as `"collector-ppms-9"` produces a unit that starts, fails to
      find its setup, exits non-zero and -- with `Restart=on-abnormal` -- does
      *not* restart, leaving a silently dead collector.

      `"full"` additionally runs upstream's {command}`tools/check-setups`,
      validating device classes, parameters and {file}`guiconfig.py` files.
      Note the cost: `nicostools/setupchecker` imports
      `nicos.clients.gui.config`, which imports `nicos.guisupport.qt`, so this
      needs a Qt binding and pulls Qt and GR into the *build* closure even on a
      headless instrument. It also imports your device classes, so
      {option}`services.nicos.extraPythonPackages` must be complete or it will
      fail on missing optional dependencies.

      In `mutable` root mode the check cannot run in a derivation -- the path
      does not exist at evaluation time -- so the `"names"` check becomes an
      `ExecStartPre` instead. `"full"` is downgraded to that there, with a
      warning: {command}`tools/check-setups` is never run against a mutable
      root.

      `false` disables it.
    '';
  };

  installTools = mkOption {
    type = types.bool;
    default = true;
    description = ''
      Put {option}`services.nicos.finalPackage` in
      {option}`environment.systemPackages`, so `nicos-client`,
      `nicos-keystore` and `nicos-aio` are on `PATH`.
    '';
  };

  openFirewall = mkOption {
    type = types.bool;
    default = false;
    description = "Open {option}`services.nicos.ports` for the enabled services.";
  };

  ports = {
    cache = mkOption {
      type = types.port;
      default = nlib.defaultPorts.cache;
      description = ''
        The cache port, for {option}`services.nicos.openFirewall` only. The
        authoritative value is the `server` parameter of the CacheServer device
        in {file}`setups/special/cache.py`.
      '';
    };
    daemon = mkOption {
      type = types.port;
      default = nlib.defaultPorts.daemon;
      description = "The execution daemon port, for {option}`services.nicos.openFirewall` only.";
    };
  };

  extraFirewallTCPPorts = mkOption {
    type = types.listOf types.port;
    default = [ ];
    description = "Extra TCP ports to open when {option}`services.nicos.openFirewall` is set.";
  };

  extraFirewallUDPPorts = mkOption {
    type = types.listOf types.port;
    default = [ ];
    description = "Extra UDP ports to open when {option}`services.nicos.openFirewall` is set.";
  };
}
