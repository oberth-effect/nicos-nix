# A NixOS configuration for an MGML instrument, transcribed from the real
# nicos_mgml/20t/nicos.conf:
#
#   [nicos]
#   pid_path = "/data/pid"
#   logging_path = "/data/log"
#   setup_subdirs = ["20t","troja"]
#   services=["cache", "poller", "daemon", "elog", "watchdog", "monitor-html"]
#
#   [environment]
#   PYTHONPATH = "/gitsrc/nicos"
#
# The PYTHONPATH line is what this flake replaces: instead of pointing NICOS at
# a checkout by hand, the setup package becomes a flake input.
{
  config,
  pkgs,
  inputs,
  ...
}:
{
  services.nicos = {
    enable = true;

    setupPackages = [
      (pkgs.nicosLib.mkSetupPackage {
        name = "nicos_mgml";
        src = inputs.nicos-mgml;
        # nicos_mgml/devices/* import these
        pythonDeps = ps: [ ps.pyserial ];
      })
    ];
    setupPackage = "nicos_mgml";
    instrument = "20t";
    setupSubdirs = [
      "20t"
      "troja"
    ];

    services = [
      "cache"
      "poller"
      "daemon"
      "elog"
      "watchdog"
      "monitor-html"
    ];

    # nicos_mgml leans on Tango/entangle (~390 references) and SECoP, and its
    # daemon.py uses the OAuth2 authenticator against user.mgml.eu.
    extras = [
      "tango"
      "notify"
      "keyring"
    ];

    # The instrument's own paths, kept as they are today.
    logDir = "/data/log";
    pidDir = "/data/pid";
    dataDir = "/data";

    # The cache store and the electronic logbook, referenced as absolute paths
    # from nicos_mgml/20t/setups/special/{cache,elog}.py.
    extraDirectories = {
      "/data/cache" = { };
      "/data/logbook".mode = "2770";
    };

    environment.TANGO_HOST = "tango.mgml.eu:10000";

    openFirewall = true;
    user = "mgml";
    group = "mgml";
  };

  # The account is a plain users.users entry, so this just merges.
  users.users.mgml = {
    isSystemUser = true;
    group = "mgml";
    extraGroups = [ "dialout" ]; # serial instruments
  };
  users.groups.mgml = { };

  # The HTML monitor writes the file named by its `filename` parameter; serve
  # it wherever you like.
  services.nginx = {
    enable = true;
    virtualHosts."status.mgml.eu".root = "/data/statmons";
  };

  # The daemon's OAuth2 client secret belongs in the keystore, not in the Nix
  # store. Populate it once, out of band:
  #
  #   sudo -u mgml \
  #     ${config.services.nicos.finalPackage}/bin/nicos-keystore \
  #       add oauth2server --storagepw <pw> --password <secret>
  #
  # services.nicos.keystorePaths defaults to [ "/etc/nicos/keystore" ], which
  # this module creates as root:mgml 0750.
}
