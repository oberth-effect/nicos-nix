# Type-check the Home Manager module.
#
# home/default.nix is otherwise never evaluated by anything, because
# home-manager is not needed to build or run any package here -- it would rot
# silently. This is the only reason home-manager is a flake input.
{
  self,
  home-manager,
  pkgs,
  lib,
  runCommand,
}:
let
  hm = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      self.homeManagerModules.nicos-gui
      {
        home = {
          username = "nicos";
          homeDirectory = "/home/nicos";
          stateVersion = "25.05";
        };

        programs.nicos-gui = {
          enable = true;
          setupPackages = [ pkgs.nicosSetupPackages.demo ];
          setupPackage = "nicos_demo";
          instrument = "demo";
          servers."demo" = {
            host = "localhost";
            user = "guest";
          };
        };
      }
    ];
  };

  gui = hm.config.programs.nicos-gui.finalPackage;
  entries = lib.attrNames hm.config.xdg.desktopEntries;
in
assert lib.assertMsg (lib.hasInfix "nicos-gui" gui.name) "finalPackage is ${gui.name}";
assert lib.assertMsg (
  entries == [ "nicos-gui-demo" ]
) "expected one desktop entry named nicos-gui-demo, got ${toString entries}";
# Force the whole activation package, so a mistake anywhere in the module is an
# evaluation error here rather than a surprise on the user's next switch.
assert lib.assertMsg (hm.activationPackage != null) "no activation package";
runCommand "nicos-hm-gui" { } ''
  echo "finalPackage    : ${gui.name}" > $out
  echo "desktop entries : ${toString entries}" >> $out
  echo "activation      : ${hm.activationPackage}" >> $out
''
