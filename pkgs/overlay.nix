# The nicos-nix overlay.
#
# `nicos-src` is threaded in from the flake so a consumer can repoint it
# (inputs.nicos-nix.inputs.nicos-src.url = "git+https://...") without forking
# this repo.
{ nicos-src }:
final: _prev:
let
  inherit (final) lib;

  # Track the nicos-src input. Upstream's newest release is 3.13.2 and the
  # GitHub mirror carries no tags, so the date of the pinned revision is the
  # only honest disambiguator.
  srcDate = nicos-src.lastModifiedDate or null;
  dateSuffix =
    if srcDate == null then
      "unknown"
    else
      "${lib.substring 0 4 srcDate}-${lib.substring 4 2 srcDate}-${lib.substring 6 2 srcDate}";
  version = "3.13.2-unstable-${dateSuffix}";
in
{
  # The pinned interpreter, carrying the Python packages nixpkgs lacks.
  # See nix/python.nix for why this is `.override` and not an overlay of python3.
  nicosPython = import ../nix/python.nix { pkgs = final; };

  # Environment-level fixes for two nixpkgs-specific problems, kept out of the
  # NICOS source so they also apply to a mutable checkout.
  # See nix/nicos_nix_fixes.py.
  nicosSitecustomize = final.nicosPython.pkgs.toPythonModule (
    final.runCommand "nicos-nix-fixes" { } ''
      site="$out/${final.nicosPython.sitePackages}"
      mkdir -p "$site"
      install -m444 ${../nix/nicos_nix_fixes.py} "$site/nicos_nix_fixes.py"

      # A .pth line beginning with `import` is executed by site.py at
      # interpreter startup. sitecustomize.py is not an option: nixpkgs' own
      # python3 already ships one, and python.buildEnv refuses the collision.
      echo "import nicos_nix_fixes" > "$site/zz-nicos-nix-fixes.pth"
    ''
  );

  # Built from the qt6 scope, so that gr-framework's qt6plugin.so and
  # python3Packages.pyqt6 share one qtbase. libGKS dlopens that plugin and
  # hands it a raw QWidget* unwrapped from PyQt via sip, so a mismatch
  # segfaults rather than erroring cleanly.
  gr-framework = final.qt6Packages.callPackage ../pkgs/gr-framework { };

  nicos-unwrapped = final.callPackage ../pkgs/nicos/unwrapped.nix {
    python = final.nicosPython;
    src = nicos-src;
    inherit version;
  };

  nicosLib = final.callPackage ../nix/lib.nix {
    python = final.nicosPython;
  };

  # `import`, not callPackage: this returns a plain attrset of derivations, and
  # callPackage would makeOverridable it -- adding `override` and
  # `overrideDerivation` attributes that then show up in `attrValues` and get
  # handed to things expecting only derivations.
  nicosSetupPackages = import ../pkgs/setup-packages.nix {
    inherit (final) lib nicosLib;
    src = nicos-src;
    inherit version;
  };

  # The stock nicos_demo setups write to paths relative to nicos_root
  # (storepath = 'data/cache', dataroot = 'data', ...), which NICOS resolves as
  # path.join(config.nicos_root, ...). That is fine in a checkout and
  # impossible against a read-only store root, so rebase them onto /tmp for
  # this throwaway demo.
  #
  # This is the norm rather than the exception in NICOS setups -- every
  # vendored facility package does it. Real deployments either use absolute
  # paths in their own setups or run services.nicos.root.mode = "mutable".
  nicosDemoRebased = final.nicosSetupPackages.demo.overrideAttrs (_: {
    # '#' is the sed delimiter here so that '|' stays ERE alternation.
    postPatch = ''
      grep -rlE "=[[:space:]]*'data(/|')" --include='*.py' nicos_demo/demo \
        | xargs -r sed -i -E "s#=[[:space:]]*'data(/|')#= '/tmp/nicos-demo/data\1#g"
    '';
  });

  # The Qt client: `nix run .#nicos-gui`.
  #
  # Ships every vendored setup package, so that with no configuration at all
  # the instrument chooser (which globs nicos_*/**/guiconfig.py under the root)
  # actually offers something. Point it elsewhere with
  #   nicos-gui -c /path/to/guiconfig.py user@host:1301
  # or override setupPackages/settings for a specific instrument.
  nicos-gui = final.nicosLib.mkNicos {
    pname = "nicos-gui";
    setupPackages = lib.attrValues final.nicosSetupPackages;
    extras = [ "gui" ];
    settings = {
      # The GUI is a client and writes neither pids nor service logs (its own
      # log goes to ~/.config/nicos/log), but leaving these relative would
      # resolve them against the read-only store root.
      pid_path = "/tmp/nicos-gui/pid";
      logging_path = "/tmp/nicos-gui/log";
    };
    mainProgram = "nicos-gui";
  };

  # A ready-to-run demo instrument: `nix run .#nicos`.
  nicos = final.nicosLib.mkNicos {
    setupPackages = [ final.nicosDemoRebased ];
    settings = {
      setup_package = "nicos_demo";
      instrument = "demo";
      pid_path = "/tmp/nicos-demo/pid";
      logging_path = "/tmp/nicos-demo/log";
    };
    mainProgram = "nicos-aio";
  };
}
