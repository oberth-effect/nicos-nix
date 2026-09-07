# The NICOS pyctl C extension: a C trace function used by the execution daemon
# to pause/stop running scripts. Published by MLZ, absent from nixpkgs.
#
# nicos/services/daemon/pyctl.py guards the import, so only `nicos-daemon`
# actually needs this -- but the daemon is a core service, so treat it as a
# hard dependency.
{
  lib,
  buildPythonPackage,
  fetchurl,
  setuptools,
  setuptools-scm,
}:

buildPythonPackage rec {
  pname = "nicos-pyctl";
  version = "1.4.1";
  pyproject = true;

  # PyPI only carries sdists up to 1.4 (1.4.1 is wheels-only there); the MLZ
  # index is the canonical publisher and does ship the 1.4.1 sdist.
  src = fetchurl {
    url = "https://forge.frm2.tum.de/packages/nicos_pyctl-${version}.tar.gz";
    hash = "sha256-1d5nzatPbLSgzAu6vMBxMNpE3Vc4+j5KYuzf3kAItbs=";
  };

  # setuptools_scm would otherwise want git metadata. The sdist ships a
  # PKG-INFO it can read, but being explicit keeps the build independent of
  # that detail.
  env.SETUPTOOLS_SCM_PRETEND_VERSION = version;

  build-system = [
    setuptools
    setuptools-scm
  ];

  # No test suite in the sdist.
  doCheck = false;

  pythonImportsCheck = [
    "nicospyctl"
    "nicospyctl.pyctl"
  ];

  meta = {
    description = "NICOS pyctl C module: trace-function based control of running Python code";
    homepage = "https://forge.frm2.tum.de/nicos/";
    license = lib.licenses.gpl2Plus;
    # C extension using the CPython frame API; never built for Windows/macOS
    # by upstream.
    platforms = lib.platforms.linux;
  };
}
