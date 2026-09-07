# The interpreter pin.
#
# nixpkgs' `python3` is 3.14; NICOS supports 3.9-3.13 (nicos/__init__.py raises
# below 3.9, and setup.py's classifiers stop at 3.13). So we pin python313 and
# inject the packages nixpkgs is missing.
#
# This is deliberately `python313.override { self; packageOverrides; }` rather
# than an overlay of `pkgs.python3`: those two arguments are consumed by the
# interpreter's passthru machinery and never enter the interpreter derivation,
# so `nicosPython.outPath == pkgs.python313.outPath` and every package we did
# not override still hits the binary cache. Overlaying `python3` would instead
# rebuild every Python consumer in the user's nixpkgs.
{
  pkgs,
  lib ? pkgs.lib,
}:
let
  base =
    pkgs.python313 or (throw ''
      nicos-nix: this nixpkgs provides no `python313`.
      NICOS supports CPython 3.9-3.13; this nixpkgs' default python3 is
      ${pkgs.python3.pythonVersion}. Either use a nixpkgs that still ships
      python313, or call nicos-nix's `lib.nicosFor` with an interpreter of
      your choice.
    '');

  python = base.override {
    self = python;
    packageOverrides = pyfinal: _pyprev: {
      lttb = pyfinal.callPackage ../pkgs/python/lttb { };
      nicos-pyctl = pyfinal.callPackage ../pkgs/python/nicos-pyctl { };
      gr = pyfinal.callPackage ../pkgs/python/gr {
        inherit (pkgs) gr-framework;
      };
      mlzlog = pyfinal.callPackage ../pkgs/python/mlzlog { };
      frappy-core = pyfinal.callPackage ../pkgs/python/frappy-core { };
    };
  };
in
assert lib.assertMsg (lib.versionAtLeast python.pythonVersion "3.9")
  "nicos-nix: NICOS requires CPython >= 3.9, got ${python.pythonVersion}.";
assert lib.assertMsg (lib.versionOlder python.pythonVersion "3.14")
  "nicos-nix: NICOS supports CPython <= 3.13, got ${python.pythonVersion}.";
python
