# MLZ's logging helper. A dependency of frappy-core, absent from nixpkgs.
{
  lib,
  buildPythonPackage,
  fetchPypi,
  setuptools,
}:

buildPythonPackage rec {
  pname = "mlzlog";
  version = "0.5.0";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-IuDDP9N0B/t60xxeMBVC56W4TByF4uA4p8bV93T/f9Q=";
  };

  build-system = [ setuptools ];

  # colorama is a Windows-only extra upstream.
  doCheck = false;
  pythonImportsCheck = [ "mlzlog" ];

  meta = {
    description = "Logging helpers used by MLZ instrument control software";
    homepage = "https://pypi.org/project/mlzlog/";
    license = lib.licenses.gpl2Plus;
    platforms = lib.platforms.all;
  };
}
