# lttb and nicos-pyctl -- the dependencies nixpkgs lacks that every NICOS
# process imports -- work on the pinned interpreter, against whatever numpy
# nixpkgs currently ships. gr, the other one, is covered by gui-offscreen.
{
  runCommand,
  nicosPython,
}:
let
  env = nicosPython.withPackages (ps: [
    ps.lttb
    ps.nicos-pyctl
    ps.numpy
  ]);
in
runCommand "nicos-python-imports" { nativeBuildInputs = [ env ]; } ''
  python3 - <<'PY'
  import numpy
  from lttb import lttb
  from nicospyctl.pyctl import Controller, ControlStop

  print("python", __import__("sys").version)
  print("numpy ", numpy.__version__)

  # pyctl: the daemon instantiates Controller with a trace callback.
  assert callable(Controller), Controller
  assert issubclass(ControlStop, BaseException), ControlStop

  # lttb: exactly the call nicos/services/monitor/html.py makes -- an (N, 2)
  # array of (time, value) down to a bucket count.
  data = numpy.stack([numpy.arange(1000.0), numpy.sin(numpy.arange(1000.0) / 50)], axis=1)
  out = lttb.downsample(data, 50)
  assert out.shape == (50, 2), out.shape
  assert out[0, 0] == data[0, 0] and out[-1, 0] == data[-1, 0]

  print("ok")
  PY
  touch $out
''
