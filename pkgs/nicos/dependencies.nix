# The single source of truth for NICOS's Python dependencies.
#
# NICOS's setup.py declares no `install_requires` at all, so this table is
# transcribed from requirements*.txt. Keeping it in one file means a nixpkgs
# rename has a blast radius of one edit.
#
# The table is nearly stable across the versions a deployment may pin (3.12.2
# and the 2026 master differ in three lines), so the few version-dependent
# entries are decided by looking at the pinned tree's own requirements.txt
# rather than by a version comparison, which a dated snapshot would defeat.
{
  lib,
  python,
  src,
}:
let
  ps = python.pkgs;
  requirements = builtins.readFile "${src}/requirements.txt";
  asksFor = name: lib.hasInfix name requirements;

  # nicos/configmod.py switched from `toml` to `tomlkit` after 3.12.
  tomlReader = if asksFor "tomlkit" then ps.tomlkit else ps.toml;
in
{
  # requirements.txt, plus systemd-python.
  #
  # systemd-python is listed as optional upstream, but the systemd units use
  # Type=notify and NoninteractiveSession.run calls systemd.daemon.notify in
  # `-D` mode, so on NixOS it is a hard dependency.
  dependencies = [
    ps.numpy
    ps.scipy
    ps.pyzmq
    ps.rsa
    ps.ldap3
    ps.psutil
    ps.html2text
    tomlReader
    ps.lttb # ours
    ps.nicos-pyctl # ours
    ps.systemd-python
  ];

  optional-dependencies = {
    # requirements-gui.txt. `gr` is a hard import in
    # nicos/guisupport/plots.py, so without it the GUI cannot plot at all.
    gui = [
      ps.pyqt6
      ps.pyqt6-webengine
      ps.pyqt6-qscintilla
      ps.gr
      ps.pillow
      ps.matplotlib
    ];

    # Tango/entangle client libraries only. The Tango DB and device servers
    # have their own lifecycle and are not this module's business.
    tango = [ ps.pytango ];

    notify = [
      ps.slack-sdk
      ps.requests-oauthlib
    ];

    keyring = [
      ps.keyring
      ps.keyrings-alt
      ps.pycryptodomex
    ];

    serial = [ ps.pyserial ];

    data = [
      ps.h5py
      ps.astropy
      ps.pillow
      ps.markdown
      ps.docutils
    ];

    # SECoP client only: a frappy server node is a separate process with its
    # own lifecycle, not this module's business.
    secop = [ ps.frappy-core ];
    # epics                          # deferred: needs EPICS base C libraries,
    #                                # which nixpkgs also lacks. See README, "Status".
  };
}
