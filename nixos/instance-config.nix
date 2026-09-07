# Turn one instance's options into a NixOS config fragment.
#
# `name` is null for the flat `services.nicos`, and would be the instance name
# under a future `services.nicos.instances.<name>`. Every unit and target name
# goes through nlib.unitNameFor/targetNameFor, so today's names are permanent.
{
  lib,
  pkgs,
  name ? null,
  cfg,
}:
let
  nlib = import ../lib/services.nix { inherit lib; };

  inherit (lib)
    optional
    optionals
    optionalAttrs
    optionalString
    filterAttrs
    mapAttrs'
    nameValuePair
    attrNames
    concatStringsSep
    ;

  unitOf =
    service:
    nlib.unitNameFor {
      instance = name;
      inherit service;
    };
  targetName = nlib.targetNameFor { instance = name; };
  target = "${targetName}.target";

  enabledServices = filterAttrs (_: s: s.enable) cfg.services;
  hasCache = enabledServices ? cache;
  mutable = cfg.root.mode == "mutable";

  setupPackageNameOf =
    p:
    p.setupPackageName or p.passthru.setupPackageName or (throw ''
      nicos-nix: services.nicos.setupPackages contains ${p.name}, which has no
      passthru.setupPackageName. Build setup packages with
      pkgs.nicosLib.mkSetupPackage.
    '');
  setupPackageNames = map setupPackageNameOf cfg.setupPackages;

  effectiveSetupPackage =
    if cfg.setupPackage != null then
      cfg.setupPackage
    else if lib.length setupPackageNames == 1 then
      lib.head setupPackageNames
    else
      null;

  # Keys this module owns; setting them through `settings` would silently
  # fight the dedicated options.
  ownedKeys = [
    "services"
    "instrument"
    "setup_package"
    "setup_subdirs"
    "user"
    "group"
    "umask"
    "pid_path"
    "logging_path"
    "systemd_props"
    "keystorepaths"
  ];
  conflictingKeys = lib.intersectLists ownedKeys (attrNames cfg.settings);

  # `services_<shorthostname>` cannot work when units are generated at
  # evaluation time.
  hostOverrideKeys = lib.filter (k: lib.hasPrefix "services_" k) (attrNames cfg.settings);

  opt = k: v: optionalAttrs (v != null && v != [ ]) { ${k} = v; };

  nicosSettings = {
    # Always written. Their upstream defaults are relative and get joined
    # onto nicos_root, which in store mode is read-only -- the first log
    # write would kill every service.
    logging_path = toString cfg.logDir;
    pid_path = toString cfg.pidDir;
    services = attrNames enabledServices;
  }
  // opt "instrument" cfg.instrument
  // opt "setup_package" effectiveSetupPackage
  // opt "setup_subdirs" cfg.setupSubdirs
  // opt "user" cfg.user
  // opt "group" cfg.group
  // opt "umask" cfg.umask
  // opt "keystorepaths" cfg.keystorePaths
  // opt "systemd_props" cfg.systemdProps
  // cfg.settings;

  # Directories the user wants importable without a rebuild. mkNicos adds the
  # *Nix-built* setup packages to PYTHONPATH itself when the root is mutable,
  # so only these plain paths belong here.
  nicosEnvironment = {
    NICOS_DATA_ROOT = toString cfg.dataDir;
  }
  // optionalAttrs (cfg.mutableSetupPackages != [ ]) {
    PYTHONPATH = concatStringsSep ":" cfg.mutableSetupPackages;
  }
  // cfg.environment;

  # The special setups the `services` list implies. A bare name loads
  # setups/special/<proc>.py; a `<proc>-<inst>` name loads
  # setups/special/<proc>-<inst>.py.
  impliedSetups = lib.unique (
    lib.mapAttrsToList (sname: s: if s.setup != null then s.setup else s.procName) enabledServices
  );

  nicosUnchecked = pkgs.nicosLib.mkNicos {
    nicos = cfg.package;
    inherit (cfg) setupPackages;
    inherit (cfg) extras extraPythonPackages extraWrapperEnv;
    settings = nicosSettings;
    environment = nicosEnvironment;
    mode = cfg.root.mode;
    rootPath = if mutable then toString cfg.root.path else null;
  };

  # Mirrors etc/nicos-late-generator's TEMPLATE, but statically.
  mkUnit =
    sname: s:
    let
      needsCache = s.procName != "cache" && hasCache;
      props = nlib.propsToAttrs (cfg.systemdProps ++ s.systemdProps);
      execArgs = [
        "${nicos}/bin/nicos-${s.procName}"
        "-D"
      ]
      ++ optionals (s.setup != null) [
        "-S"
        s.setup
      ]
      ++ s.extraArgs;
    in
    nameValuePair (unitOf sname) (_: {
      # A function, not a bare attrset: systemd.services uses
      # shorthandOnlyDefinesConfig, so an attrset definition is treated as pure
      # config and `imports` would be looked up as an option name.
      imports = [ s.unit ]; # the per-service escape hatch, merged last

      description = "NICOS ${sname} service";
      documentation = [ "https://forge.frm2.tum.de/nicos/doc/nicos-stable/" ];
      partOf = [ target ];
      wantedBy = [ target ];
      after = [ "network.target" ] ++ optional needsCache "${unitOf "cache"}.service";
      requires = optional needsCache "${unitOf "cache"}.service";

      serviceConfig = {
        # NoninteractiveSession.run reaches daemonize() only in the `elif
        # daemon:` branch, so `-D` never forks: the main PID is the service and
        # it calls sd_notify itself.
        Type = "notify";
        # Deliberately NOT NotifyAccess=all: the poller master respawns child
        # pollers *with* -D, so each child also calls sd_notify. Under `all` a
        # child's READY=1 could mark the unit ready before the master is.
        NotifyAccess = "main";

        ExecStart = lib.escapeShellArgs execArgs;
        Restart = s.restart;
        RestartSec = 30;
        TimeoutStartSec = s.timeoutStartSec;
        User = cfg.user;
        Group = cfg.group;
        UMask = cfg.umask;
        Slice = "nicos.slice";
        SyslogIdentifier = unitOf sname;

        # Hardening stops exactly where upstream's stops. NICOS drives serial,
        # USB, Tango and EPICS hardware; PrivateDevices / ProtectHome /
        # ProtectSystem=strict break real instruments. They stay opt-in via the
        # per-service `unit` option.
        ProtectSystem = "full";
        ReadWritePaths =
          map (p: "-${toString p}") (
            [
              cfg.logDir
              cfg.pidDir
              cfg.dataDir
            ]
            ++ attrNames cfg.extraDirectories
          )
          ++ optional mutable "-${toString cfg.root.path}";
      }
      // optionalAttrs (mutable && cfg.checkSetups != false) {
        ExecStartPre = "${mutableSetupCheckScript} ${if s.setup != null then s.setup else s.procName}";
      }
      // props;

      # `git` is on PATH for mutable roots: a checkout has real git metadata
      # and nicos/_vendor/gitversion.py shells out to `git describe` before
      # falling back to RELEASE-VERSION. With neither, `import nicos` raises.
      path = optionals mutable [ pkgs.git ];
    });

  tmpfilesFor =
    dirs:
    lib.listToAttrs (
      map (
        d:
        nameValuePair (toString d.path) {
          d = {
            user = cfg.user;
            group = cfg.group;
            inherit (d) mode;
          };
        }
      ) dirs
    );
  setupCheck =
    if cfg.checkSetups == false || mutable then
      null
    else
      pkgs.nicosLib.checkSetups {
        nicos = nicosUnchecked;
        setupNames = impliedSetups;
        level = cfg.checkSetups;
      };

  # In mutable mode the check cannot be a derivation -- the path does not exist
  # at evaluation time -- so it runs before each start. A store script, not an
  # inline ExecStartPre: systemd will not parse a multi-line command value.
  mutableSetupCheckScript = pkgs.writeShellScript "nicos-check-setup-exists" ''
    set -eu
    ${nicosUnchecked}/bin/nicos-python ${./check-setup-exists.py} "$1"
  '';

  # Make the package the services reference depend on the check, so a broken
  # setup fails the build rather than the instrument. A symlink keeps the
  # runtime closure identical.
  # `nicos` is what the units, systemPackages and finalPackage all reference,
  # so making it depend on the check is what actually gates the build. The
  # symlink keeps the runtime closure identical to nicosUnchecked.
  nicos =
    if setupCheck == null then
      nicosUnchecked
    else
      pkgs.runCommand "${nicosUnchecked.name}-checked"
        {
          # a build input, so it has to succeed before this exists
          nativeBuildInputs = [ setupCheck ];
          passthru = nicosUnchecked.passthru // {
            inherit setupCheck;
            unchecked = nicosUnchecked;
          };
          inherit (nicosUnchecked) meta;
        }
        ''
          ln -s ${nicosUnchecked} $out
        '';
in
{
  services.nicos.finalPackage = nicos;

  systemd.services = mapAttrs' mkUnit enabledServices;

  systemd.targets.${targetName} = {
    description = "NICOS lab control system${optionalString (name != null) " (${name})"}";
    wants = [ "network-online.target" ];
    requires = optional cfg.requireNetworkOnline "network-online.target";
    after = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
  };

  systemd.slices.nicos = {
    description = "Slice for all NICOS services";
  };

  # A static system user, not DynamicUser: instrument data outlives the service
  # and needs stable ownership (dynamic UIDs are recycled), the account needs
  # supplementary groups such as dialout, data often lives on NFS, and
  # DynamicUser implies ProtectSystem=strict + PrivateTmp, which breaks device
  # access.
  users.users = optionalAttrs (cfg.user == "nicos") {
    nicos = {
      description = "NICOS lab control system";
      isSystemUser = true;
      group = cfg.group;
      home = toString cfg.dataDir;
    };
  };
  users.groups = optionalAttrs (cfg.group == "nicos") { nicos = { }; };

  # tmpfiles rather than StateDirectory=/LogsDirectory=: those only work under
  # /var/lib and friends, and real deployments use /data/log, /data/pid,
  # /data/cache. This also means the directories exist before any unit starts,
  # so a hand-run nicos-keystore or nicos-aio works on a fresh boot.
  systemd.tmpfiles.settings = {
    "10-nicos" =
      tmpfilesFor (
        [
          {
            path = cfg.logDir;
            mode = "0750";
          }
          {
            path = cfg.pidDir;
            mode = "0750";
          }
          # setgid, so that with UMask=002 instrument data is group-shareable
          {
            path = cfg.dataDir;
            mode = "2770";
          }
        ]
        ++ lib.mapAttrsToList (path: d: {
          inherit path;
          inherit (d) mode;
        }) cfg.extraDirectories
      )
      // {
        "/etc/nicos".d = {
          user = "root";
          group = cfg.group;
          mode = "0750";
        };
      };

    # In mutable mode the module still owns nicos.conf: an `L+` rule replaces
    # whatever is there on every activation, so a rebuild updates it and it
    # cannot drift out of sync with these options.
    "20-nicos-root" = optionalAttrs (mutable && cfg.root.manageNicosConf) {
      "${toString cfg.root.path}/nicos.conf"."L+".argument = "${nicos.passthru.nicosConf}";
    };
  };

  networking.firewall = lib.mkIf cfg.openFirewall {
    allowedTCPPorts =
      optional hasCache cfg.ports.cache
      ++ optional (enabledServices ? daemon) cfg.ports.daemon
      ++ cfg.extraFirewallTCPPorts;
    allowedUDPPorts = optional hasCache cfg.ports.cache ++ cfg.extraFirewallUDPPorts;
  };

  environment.systemPackages = optional cfg.installTools nicos;

  # Optionally populate a mutable root once, if it is still empty. Never
  # touches it again -- the point of the mode is that the checkout is yours.
  system.activationScripts = optionalAttrs (mutable && cfg.root.seed != null) {
    nicos-seed-root.text = ''
      if [ ! -e ${toString cfg.root.path}/nicos/configmod.py ]; then
        echo "nicos-nix: seeding ${toString cfg.root.path} from ${cfg.root.seed}"
        mkdir -p ${toString cfg.root.path}
        cp -a ${cfg.root.seed}/. ${toString cfg.root.path}/
        chmod -R u+w ${toString cfg.root.path}

        # Strip the precompiled bytecode, or the checkout is not actually
        # mutable: nicos-unwrapped compiles with --invalidation-mode
        # unchecked-hash, which Python never revalidates, so editing a .py
        # would silently have no effect.
        find ${toString cfg.root.path} -type d -name __pycache__ -prune -exec rm -rf {} +

        chown -R ${cfg.user}:${cfg.group} ${toString cfg.root.path}
      fi
    '';
  };

  assertions = [
    {
      assertion = enabledServices == { } || cfg.instrument != null || cfg.settings ? instrument;
      message = "services.nicos.instrument must be set: it selects the setup subdirectory and the guiconfig.py location.";
    }
    {
      assertion = enabledServices == { } || mutable || effectiveSetupPackage != null;
      message = ''
        services.nicos.setupPackage must be set when services.nicos.setupPackages
        has other than exactly one entry (found: ${toString (lib.length setupPackageNames)}).
      '';
    }
    {
      assertion =
        effectiveSetupPackage == null || mutable || lib.elem effectiveSetupPackage setupPackageNames;
      message = ''
        services.nicos.setupPackage = "${toString effectiveSetupPackage}" is not among
        services.nicos.setupPackages (${concatStringsSep ", " setupPackageNames}).
        Only one setup package is active per process, but it must be present in the root.
      '';
    }
    {
      assertion = lib.length (lib.unique setupPackageNames) == lib.length setupPackageNames;
      message = "services.nicos.setupPackages contains two packages with the same setupPackageName.";
    }
    {
      assertion = lib.all (p: lib.hasPrefix "/" (toString p)) [
        cfg.logDir
        cfg.pidDir
        cfg.dataDir
      ];
      message = ''
        services.nicos.{logDir,pidDir,dataDir} must be absolute: NICOS resolves
        relative paths against nicos_root, which in store mode is a read-only
        /nix/store path.
      '';
    }
    {
      assertion = conflictingKeys == [ ];
      message = ''
        services.nicos.settings must not set ${concatStringsSep ", " conflictingKeys};
        use the dedicated services.nicos.* options instead.
      '';
    }
    {
      assertion = hostOverrideKeys == [ ];
      message = ''
        services.nicos.settings.${lib.head (hostOverrideKeys ++ [ "services_<host>" ])}:
        per-host `services_<hostname>` overrides cannot work here, because this
        module generates the systemd units at evaluation time instead of running
        nicos-late-generator at boot. Give each host its own nixosConfiguration.
      '';
    }
    {
      assertion = !mutable || cfg.root.path != null;
      message = "services.nicos.root.path must be set when services.nicos.root.mode = \"mutable\".";
    }
    {
      assertion = cfg.root.path == null || lib.hasPrefix "/" (toString cfg.root.path);
      message = "services.nicos.root.path must be absolute.";
    }
  ];

  warnings =
    # The Qt monitor needs a display; upstream explicitly warns against running
    # it from the startup system.
    map (
      n:
      "services.nicos.services.\"${n}\" runs the Qt status monitor as a system service. "
      + "It needs an X/Wayland display and will not start under systemd; upstream warns "
      + "against this. Use an HTML monitor setup (e.g. \"monitor-html\") for headless "
      + "operation, or run the Qt monitor in a user session."
    ) (attrNames (filterAttrs (_: s: s.procName == "monitor" && s.setup == null) enabledServices))

    ++ optional (enabledServices != { } && !hasCache) (
      "services.nicos: no `cache` service is configured. The other services will need an "
      + "explicit cache host in their setups, and get no startup ordering dependency on it."
    )

    ++ map (
      n:
      "services.nicos.services.\"${n}\" contains more than one `-`. This module handles it, "
      + "but upstream's nicos-late-generator does name.split('-') and raises on such names, "
      + "so the generated nicos.conf is not portable off NixOS."
    ) (attrNames (filterAttrs (n: _: (nlib.splitServiceName n).dashes > 1) enabledServices))

    ++
      optional
        (cfg.setupSubdirs != [ ] && cfg.instrument != null && !(lib.elem cfg.instrument cfg.setupSubdirs))
        (
          "services.nicos.setupSubdirs does not contain services.nicos.instrument "
          + "(\"${cfg.instrument}\"), so that instrument's own setups will not be loaded."
        )

    ++ optional (cfg.environment ? PYTHONPATH) (
      "services.nicos.environment.PYTHONPATH is set by hand. NICOS prepends it to sys.path, "
      + "so it shadows the Nix-built NICOS and setup packages with whatever is at that path. "
      + "Use services.nicos.mutableSetupPackages instead."
    )

    ++ optional mutable (
      "services.nicos.root.mode = \"mutable\": the running NICOS code comes from "
      + "${toString cfg.root.path} and is no longer pinned by the flake, so nixos-rebuild "
      + "cannot reproduce this deployment."
    );
}
