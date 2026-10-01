# Evaluation-only assertions on unit generation. Runs in seconds and needs no
# VM, so this is where rules that are easy to break silently get pinned.
#
# Asserts on the structured `systemd.services.<n>` values rather than on
# rendered unit text: rendering pulls in the whole filesystem/zfs option
# closure of a stub nixosSystem, which recurses.
{
  self,
  nixpkgs,
  pkgs,
  lib,
  runCommand,
}:
let
  mkSystem =
    modules:
    (nixpkgs.lib.nixosSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [
        self.nixosModules.nicos
        {
          nixpkgs.pkgs = pkgs;
          system.stateVersion = "25.05";
        }
      ]
      ++ modules;
    }).config;

  base = {
    services.nicos = {
      enable = true;
      setupPackages = [ pkgs.nicosSetupPackages.demo ];
      instrument = "demo";
    };
  };

  cfg = mkSystem [
    base
    {
      # The list and attrset forms merge, which is the point of the coercedTo:
      # paste the list out of an existing nicos.conf, then tune one service.
      services.nicos.services = lib.mkMerge [
        [
          "cache"
          "poller"
          "monitor-html"
          "collector-ppms9"
        ]
        { "collector-ppms9".unit.serviceConfig.Nice = -5; }
      ];
    }
  ];

  svc = n: cfg.systemd.services."nicos-${n}";
  sc = n: (svc n).serviceConfig;

  # This module's *failing* assertions only.
  #
  # Two reasons for the shape. A bare nixosSystem stub also fails NixOS's own
  # root-filesystem and bootloader assertions, and counting those would make
  # every negative test below pass for the wrong reason. And the filter must
  # come before touching `message`, because some nixpkgs assertions build their
  # message from values that only exist when the assertion actually fails
  # (nixos/modules/tasks/filesystems.nix throws on `cycle` otherwise).
  nicosFailures =
    c:
    lib.filter (a: lib.hasInfix "services.nicos" a.message) (lib.filter (a: !a.assertion) c.assertions);

  assertionsFail = modules: nicosFailures (mkSystem modules) != [ ];

  # A hard eval failure -- a type error, an enum violation, a throw -- while
  # forcing whatever `force` picks out of the evaluated config.
  throwsOnEval =
    force: modules: !(builtins.tryEval (builtins.deepSeq (force (mkSystem modules)) true)).success;

  checks = {
    # `monitor-html` is not a binary: it is nicos-monitor with -S monitor-html.
    monitor-html-maps-to-monitor =
      lib.hasInfix "bin/nicos-monitor" (sc "monitor-html").ExecStart
      && lib.hasInfix "-S monitor-html" (sc "monitor-html").ExecStart;
    # Instance-suffixed names stay expressible.
    collector-instance-setup =
      lib.hasInfix "bin/nicos-collector" (sc "collector-ppms9").ExecStart
      && lib.hasInfix "-S collector-ppms9" (sc "collector-ppms9").ExecStart;
    # Upstream's rule: monitors restart on-failure, everything else on-abnormal.
    monitor-restart-on-failure = (sc "monitor-html").Restart == "on-failure";
    poller-restart-on-abnormal = (sc "poller").Restart == "on-abnormal";
    # The per-service escape hatch reaches the unit.
    per-service-override = (sc "collector-ppms9").Nice == -5;
    # The cache dependency rule, in both directions.
    poller-requires-cache = (svc "poller").requires == [ "nicos-cache.service" ];
    cache-requires-nothing = (svc "cache").requires == [ ];
    poller-after-cache = lib.elem "nicos-cache.service" (svc "poller").after;
    # Hardening stays exactly at upstream's level.
    protect-system-full = (sc "cache").ProtectSystem == "full";
    # The notify contract, and the deliberate NotifyAccess choice: the poller
    # respawns children with -D, so `all` would let a child's READY=1 through.
    type-notify = (sc "cache").Type == "notify";
    notify-access-main = (sc "cache").NotifyAccess == "main";
    # The poller gets the larger start timeout: it loads every setup and forks
    # a child per setup.
    poller-timeout = (sc "poller").TimeoutStartSec == 900;
    cache-timeout = (sc "cache").TimeoutStartSec == 300;
    slice = (sc "cache").Slice == "nicos.slice";
    # Only the enabled services get units.
    exactly-four-units =
      lib.length (lib.filter (lib.hasPrefix "nicos-") (lib.attrNames cfg.systemd.services)) == 4;
    # network-online is wanted, not required, so a failing wait-online does not
    # take the instrument down at boot.
    target-wants-network = cfg.systemd.targets.nicos.wants == [ "network-online.target" ];
    target-not-requires-network = cfg.systemd.targets.nicos.requires == [ ];
    # A valid configuration fires no assertion.
    no-assertions =
      let
        bad = nicosFailures cfg;
      in
      if bad == [ ] then
        true
      else
        throw "unexpected assertion(s) for a valid config: ${
          lib.concatStringsSep " | " (map (a: a.message) bad)
        }";

    # Negative cases.
    rejects-host-override = assertionsFail [
      base
      { services.nicos.settings.services_myhost = [ "cache" ]; }
    ];
    # Keys the dedicated options own are refused from `settings`.
    rejects-owned-key-in-settings = assertionsFail [
      base
      { services.nicos.settings.logging_path = "log"; }
    ];
    # types.path refuses a relative value by itself, so this is a type error,
    # not one of the module's assertions.
    rejects-relative-logdir = throwsOnEval (c: c.services.nicos.logDir) [
      base
      { services.nicos.logDir = "log"; }
    ];
    rejects-mutable-without-path = assertionsFail [
      base
      { services.nicos.root.mode = "mutable"; }
    ];
    rejects-unknown-service =
      throwsOnEval
        # attrNames alone does not force the submodule, so the `procName` enum
        # would never be checked; mapping over it does.
        (c: lib.mapAttrs (_: sv: sv.procName) c.services.nicos.services)
        [
          base
          { services.nicos.services = [ "pollr" ]; }
        ];
  };

  failed = lib.attrNames (lib.filterAttrs (_: v: !v) checks);
in
if failed != [ ] then
  throw "nicos-nix eval checks FAILED: ${lib.concatStringsSep ", " failed}"
else
  runCommand "nicos-eval-checks" { } ''
    printf '%s\n' ${lib.escapeShellArgs (lib.attrNames checks)} > $out
  ''
