# The NICOS source tree, prepared but not composed.
#
# setup.py is deliberately never invoked. Its custom `nicosinstall` command
# forces install_purelib/install_platlib to $base (a flat prefix, not
# site-packages), defaults the prefix to /opt/nicos, mkpath()s pid/ and log/
# inside that prefix and writes a mutable nicos.conf -- none of which survives
# a read-only store. Copying the tree produces exactly what nicosinstall would
# have, with none of the fighting.
{
  lib,
  stdenvNoCC,
  python,
  src,
  version,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "nicos-unwrapped";
  inherit version src;

  strictDeps = true;
  nativeBuildInputs = [ python ];

  dontConfigure = true;
  dontBuild = true;

  postPatch = ''
    # Freeze the version (see pkgs/nicos/gitversion.py for why). The greps are
    # a shape check: if upstream refactors this module the build fails loudly
    # instead of silently dropping the fix.
    for needle in 'def get_nicos_version' 'config.apply()'; do
      if ! grep -q "$needle" nicos/_vendor/gitversion.py; then
        echo "nicos-nix: nicos/_vendor/gitversion.py no longer contains '$needle';" >&2
        echo "  upstream refactored it, so pkgs/nicos/gitversion.py needs updating." >&2
        exit 1
      fi
    done
    cp ${./gitversion.py} nicos/_vendor/gitversion.py
    substituteInPlace nicos/_vendor/gitversion.py \
      --subst-var-by version "${finalAttrs.version}"

    # NICOS 3.12 and older use numpy.mat, which NumPy 2 (what nixpkgs ships)
    # removed; nicos.devices.tas.plotting and nicos.commands.tas then fail to
    # import. Upstream later switched to asmatrix, the documented drop-in, so
    # apply that wherever the pinned tree still has the old spelling.
    if grep -qE 'from numpy import .*\bmat\b' nicos/devices/tas/plotting.py; then
      substituteInPlace nicos/devices/tas/plotting.py \
        --replace-fail ', mat, ' ', asmatrix, ' \
        --replace-fail 'matrix = mat(' 'matrix = asmatrix('
    fi
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"

    # Everything that has to be reachable from nicos_root at runtime:
    #   nicos/       the core package
    #   nicostools/  imported by tools/check-setups
    #   bin/         RESPAWNED at runtime by the poller, daemon and watchdog
    #   etc/         upstream's init script and unit templates (reference only)
    #   tools/       check-setups and friends
    #   template/    the default value of the Experiment device's `templates`
    #   resources/   icons and .qrc sources
    for d in nicos nicostools bin etc tools template resources; do
      if [ ! -e "$d" ]; then
        echo "nicos-nix: expected '$d' in the NICOS source tree" >&2
        exit 1
      fi
      cp -a "$d" "$out/"
    done

    echo "${finalAttrs.version}" > "$out/nicos/RELEASE-VERSION"

    # Shebangs are left alone: the interpreter is only known once the extras
    # are chosen, i.e. in mkNicosRoot.
    runHook postInstall
  '';

  postFixup = ''
    # Precompile. Without this every service recompiles an 8 MB tree on each
    # start and cannot cache the result, because the store is read-only
    # (CPython silently swallows the EROFS).
    #
    # unchecked-hash records the source hash in the .pyc and never revalidates
    # it: immune to mtime normalisation, to lndir symlinks, and to being
    # consumed from a different store path than it was compiled in.
    #
    # setups/ are exec'd rather than imported, so they get no .pyc.
    # No `|| true`: over the core tree this doubles as a free syntax check.
    ${python.pythonOnBuildForHost.interpreter} -m compileall \
      -q -f -j "$NIX_BUILD_CORES" --invalidation-mode unchecked-hash \
      -x '.*/(setups|testscripts)/.*' \
      "$out/nicos" "$out/nicostools"
  '';

  passthru = {
    inherit python;
  }
  // import ./dependencies.nix { inherit lib python src; };

  meta = {
    description = "NICOS instrument control system (prepared source tree, not composed)";
    homepage = "https://forge.frm2.tum.de/nicos/";
    license = lib.licenses.gpl2Plus;
    platforms = lib.platforms.linux;
  };
})
