# Largest-Triangle-Three-Buckets downsampling. A hard NICOS dependency
# (nicos/services/monitor/html.py does `from lttb import lttb`), absent from
# nixpkgs.
{
  lib,
  buildPythonPackage,
  fetchPypi,
  flit-core,
  numpy,
  pytestCheckHook,
  hypothesis,
}:

buildPythonPackage rec {
  pname = "lttb";
  version = "0.3.2";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-t/KA061xpoSX917uPQPxvKzKwNVsQwt6+lYmgr9sacA=";
  };

  # Upstream declares `numpy ~= 1.17`, i.e. `>=1.17, ==1.*`, and unlike NICOS
  # itself lttb states it as real dist metadata -- so nixpkgs' runtime-deps
  # check enforces it and fails against numpy 2.x. The pin is stale rather
  # than meaningful: the module uses only indexing, `numpy.abs` and
  # `numpy.array_split`, none of which changed in numpy 2.
  pythonRelaxDeps = [ "numpy" ];

  build-system = [ flit-core ];
  dependencies = [ numpy ];

  nativeCheckInputs = [
    pytestCheckHook
    hypothesis
  ];

  pythonImportsCheck = [
    "lttb"
    "lttb.lttb"
  ];

  meta = {
    description = "Largest-Triangle-Three-Buckets algorithm for downsampling time series-like data";
    homepage = "https://sr.ht/~javiljoen/lttb/";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
