# The GR Python bindings (PyPI project name: `gr`; upstream repo: sciapp/python-gr).
#
# The distribution also ships the top-level `qtgr` module, which is what
# nicos/guisupport/qtgr.py imports -- so nothing extra is needed for it.
{
  lib,
  buildPythonPackage,
  fetchPypi,
  setuptools,
  wheel,
  vcversioner,
  numpy,
  gr-framework,
}:

buildPythonPackage rec {
  pname = "gr";
  version = "1.30.0";
  pyproject = true;

  # sdist only: the project has published no wheels since 0.15.0.
  src = fetchPypi {
    inherit pname version;
    hash = "sha256-W9qf0Kga5xngwIJeAi4AEEJuHQ+ZAV7PcJ7TPev/2KY=";
  };

  # Two separate, independent runtime searches hard-code /usr/local/gr/lib:
  # gr/runtime_helper.py (for libGR) and gr3/__init__.py, which carries its own
  # copy of load_runtime (for libGR3). Patching only the first leaves
  # `import gr3` -- and so `import qtgr`, and so the whole NICOS GUI -- broken.
  #
  # Patched rather than left to $GRLIB so that a bare `python -c "import gr3"`
  # works, not only NICOS's own wrappers.
  postPatch = ''
    substituteInPlace gr/runtime_helper.py gr3/__init__.py \
      --replace-fail "'/usr/local/gr/lib'" "'${gr-framework}/lib'"
  '';

  # setup.py otherwise downloads a prebuilt runtime at build time. Both network
  # calls are defeated without patching:
  #   GR_VERSION=minimum  skips runtime_helper.latest_runtime_version(), which
  #                       urlopen()s the GitHub releases API;
  #   GRLIB               makes load_runtime(silent=True) succeed, so
  #                       DownloadBinaryDistribution.run() skips the tarball
  #                       fetch entirely.
  # Do NOT set GR_FORCE_DOWNLOAD.
  env = {
    GR_VERSION = "minimum";
    GRLIB = "${gr-framework}/lib";
  };

  build-system = [
    setuptools
    wheel
    vcversioner
  ];

  dependencies = [ numpy ];

  # GRLIB above is needed during the build, but must not survive into the
  # import check: with it set the check passes through the environment
  # variable and hides a broken patched search path -- which is exactly how
  # the missing gr3 patch first went unnoticed.
  preFixup = "unset GRLIB";

  # qtgr is excluded: importing it requires a Qt binding, which the headless
  # closure does not have.
  pythonImportsCheck = [
    "gr"
    "gr.pygr"
    "gr3"
  ];

  meta = {
    description = "Python visualisation framework built on the GR framework";
    homepage = "https://gr-framework.org/python.html";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
