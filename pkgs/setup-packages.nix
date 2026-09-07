# The setup packages vendored in the NICOS repository.
#
# Each is built from the same `nicos-src` as the core, so they never skew.
# Out-of-tree ones are built the same way:
#
#   nicosLib.mkSetupPackage { name = "nicos_mylab"; src = <your git input>; }
{
  lib,
  nicosLib,
  src,
  version,
}:
let
  facilities = [
    "batan"
    "cvut"
    "demo"
    "ess"
    "inl"
    "isis"
    "jcns"
    "lahn"
    "mgml"
    "mlz"
    "pnpi"
    "sinq"
    "tum"
    "tuw"
    "virt_mlz"
    "virt_sinq"
  ];
in
lib.genAttrs facilities (
  facility:
  nicosLib.mkSetupPackage {
    name = "nicos_${facility}";
    subdir = "nicos_${facility}";
    inherit src version;
  }
)
