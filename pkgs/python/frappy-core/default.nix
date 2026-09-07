# frappy: the SECoP server and client implementation, used by
# nicos.devices.secop. On PyPI, but absent from nixpkgs.
#
# The distribution installs several top-level packages (frappy, frappy_demo,
# frappy_ess, frappy_mlz, frappy_psi); NICOS imports `frappy`.
{
  lib,
  buildPythonPackage,
  fetchPypi,
  setuptools,
  mlzlog,
  psutil,
  pyserial,
  python-daemon,
}:

buildPythonPackage rec {
  pname = "frappy-core";
  version = "0.20.9";
  pyproject = true;

  src = fetchPypi {
    pname = "frappy_core";
    inherit version;
    hash = "sha256-PaRis9TpkApxa9UrgGznxjrzSGbtKvxs6Tkcks3RIkQ=";
  };

  build-system = [ setuptools ];

  dependencies = [
    mlzlog
    psutil
    pyserial
    python-daemon
  ];

  # setup.py imports frappy.version.get_version(), which reads
  # frappy/RELEASE-VERSION -- present in the sdist, so no git is needed.

  # The test suite is excluded from the sdist's packages.
  doCheck = false;
  pythonImportsCheck = [ "frappy" ];

  meta = {
    description = "Implementation of the SECoP sample environment communication protocol";
    homepage = "https://github.com/SampleEnvironment/frappy";
    license = lib.licenses.gpl2Plus;
    platforms = lib.platforms.linux;
  };
}
