# The setup packages vendored in the NICOS repository, keyed by facility:
# nicos_mgml/ becomes `mgml`.
#
# Discovered from the source tree rather than listed, because the set differs
# between NICOS versions (nicos_cvut, for one, is newer than 3.12) and a
# deployment pins whichever version it needs. Each is built from the same
# source as the core (final.nicosSource), so they never skew.
#
# Reading the tree at evaluation time is fine for a flake input, which is a
# plain store path; a *derivation* as nicosSource (fetchgit and friends) would
# make this import-from-derivation.
#
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
  entries = builtins.readDir "${src}";
  isSetupPackage =
    name: type:
    type == "directory"
    && lib.hasPrefix "nicos_" name
    && builtins.pathExists "${src}/${name}/__init__.py";
  packages = lib.attrNames (lib.filterAttrs isSetupPackage entries);
in
lib.listToAttrs (
  map (
    name:
    lib.nameValuePair (lib.removePrefix "nicos_" name) (
      nicosLib.mkSetupPackage {
        inherit name src version;
        subdir = name;
      }
    )
  ) packages
)
