# The interpreter pin.
#
# nixpkgs' `python3` is 3.14; NICOS supports 3.9-3.13 (nicos/__init__.py raises
# below 3.9, and setup.py's classifiers stop at 3.13). So we pin python313 and
# inject the packages nixpkgs is missing.
#
# This is deliberately `.override { self; packageOverrides; }` rather than an
# overlay of `pkgs.python3`: those two arguments are consumed by the
# interpreter's passthru machinery and never enter the interpreter derivation,
# so `nicosPython.outPath == pkgs.python313.outPath` and every package we did
# not override still hits the binary cache. Overlaying `python3` would instead
# rebuild every Python consumer in the user's nixpkgs.
{
  pkgs,
  lib ? pkgs.lib,
  # An explicit interpreter, for `nicos-nix.lib.nicosFor pkgs pkgs.python314`.
  # null means "the pin".
  basePython ? null,
}:
let
  explicit = basePython != null;

  base =
    if explicit then
      basePython
    else
      pkgs.python313 or (throw ''
        nicos-nix: this nixpkgs provides no `python313`.
        NICOS supports CPython 3.9-3.13; this nixpkgs' default python3 is
        ${pkgs.python3.pythonVersion}. Either use a nixpkgs that still ships
        python313, or choose an interpreter explicitly:

          nicos-nix.lib.nicosFor pkgs pkgs.python314
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
# The lower bound is a hard error: nicos/__init__.py raises ImportError below
# 3.9, so nothing would work. The upper bound is only what upstream advertises,
# so it warns rather than refusing -- otherwise `nicosFor` could never be used
# to try a newer interpreter, which is its whole purpose.
assert lib.assertMsg (lib.versionAtLeast python.pythonVersion "3.9")
  "nicos-nix: NICOS requires CPython >= 3.9 (enforced in nicos/__init__.py), got ${python.pythonVersion}.";
lib.warnIf (!lib.versionOlder python.pythonVersion "3.14")
  "nicos-nix: using CPython ${python.pythonVersion}; NICOS advertises support only up to 3.13."
  python
