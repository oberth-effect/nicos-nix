# services.nicos.root.mode = "mutable": verify that nicos_root really becomes a
# writable path outside the store, and that everything still resolves.
#
# Done as a plain derivation rather than a VM test: the mechanism under test is
# path resolution in the wrappers, which needs no systemd. The sandbox's /tmp is
# a writable tmpfs, so it stands in for the checkout.
{
  runCommand,
  nicosLib,
  nicos-unwrapped,
  nicosDemoRebased,
}:
let
  rootPath = "/tmp/nicos-mutable-check";

  mutable = nicosLib.mkNicos {
    pname = "nicos-mutable-check";
    mode = "mutable";
    inherit rootPath;
    # In mutable mode setup packages are made importable via PYTHONPATH rather
    # than linked into the root, so this still works alongside a hand-managed
    # core checkout.
    setupPackages = [ nicosDemoRebased ];
    settings = {
      setup_package = "nicos_demo";
      instrument = "demo";
      pid_path = "/tmp/nicos-mutable-check-state/pid";
      logging_path = "/tmp/nicos-mutable-check-state/log";
    };
  };
in
runCommand "nicos-mutable-root" { } ''
  export HOME="$TMPDIR"

  # Stand in for `git clone`: a writable copy of the NICOS tree.
  mkdir -p ${rootPath}
  cp -a ${nicos-unwrapped}/. ${rootPath}/
  chmod -R u+w ${rootPath}

  # What the module's seed script does, and why it must: nicos-unwrapped
  # precompiles with --invalidation-mode unchecked-hash, which Python never
  # revalidates. Leaving that bytecode in place makes a "mutable" checkout
  # silently immutable -- edits to .py files would have no effect.
  find ${rootPath} -type d -name __pycache__ -prune -exec rm -rf {} +

  # What the NixOS module places with a systemd.tmpfiles `L+` rule.
  ln -sf ${mutable.passthru.nicosConf} ${rootPath}/nicos.conf

  mkdir -p /tmp/nicos-mutable-check-state/{pid,log}

  echo "=== nicos_root must be the checkout, not a store path"
  got=$(${mutable}/bin/nicos-python -c 'from nicos import config; print(config.nicos_root)')
  echo "    nicos_root = $got"
  test "$got" = "${rootPath}" || { echo "nicos-nix: expected nicos_root ${rootPath}, got $got" >&2; exit 1; }

  echo "=== the setup package resolves through [environment] PYTHONPATH"
  ${mutable}/bin/nicos-python -c '
  from nicos import config
  print("    setup_package      =", config.setup_package)
  print("    setup_package_path =", config.setup_package_path)
  print("    instrument         =", config.instrument)
  print("    logging_path       =", config.logging_path)
  assert config.setup_package == "nicos_demo", config.setup_package
  assert config.instrument == "demo", config.instrument
  assert config.setup_package_path.startswith("/nix/store/"), \
      "the setup package should still be Nix-pinned"
  '

  echo "=== editing the checkout takes effect with no rebuild"
  # A marker only reachable if the running code is the checkout.
  echo 'NICOS_NIX_MUTABLE_MARKER = 42' >> ${rootPath}/nicos/configmod.py
  v=$(${mutable}/bin/nicos-python -c 'import nicos.configmod as c; print(c.NICOS_NIX_MUTABLE_MARKER)')
  test "$v" = "42" || { echo "nicos-nix: edit did not take effect (got '$v')" >&2; exit 1; }
  echo "    marker read back: $v"

  echo "=== the respawn targets exist in the checkout's bin/"
  for b in nicos-poller nicos-simulate nicos-script; do
    test -x ${rootPath}/bin/$b || { echo "nicos-nix: missing ${rootPath}/bin/$b" >&2; exit 1; }
  done

  echo "MUTABLE ROOT OK"
  touch $out
''
