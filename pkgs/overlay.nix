# The nicos-nix overlay.
#
# `nicos-src` is threaded in from the flake, but only as the *default*. The
# packages read `final.nicosSource` and `final.nicosVersion`, so a later
# overlay can pin another NICOS per package set -- and therefore per NixOS
# host -- and the core, the vendored setup packages and the GUI all follow.
# A consumer can also repoint the input itself:
#   inputs.nicos-nix.inputs.nicos-src.url = "github:mlz-ictrl/nicos/v3.13.2";
# See the README, "Pinning NICOS".
{
  nicos-src,
  # The release `nicos-src` is pinned to, e.g. "3.12.2", or null for an
  # untagged snapshot.
  release ? null,
}:
final: _prev:
let
  inherit (final) lib;
in
{
  # The NICOS source tree everything below is built from.
  nicosSource = nicos-src;

  # The version label, also written to nicos/RELEASE-VERSION and reported by
  # NICOS itself. A flake input records only a commit, never the tag it was
  # reached through, so the flake states the release it pinned; without that,
  # the pin's date is the only honest disambiguator. Set this together with
  # nicosSource when pinning something else, or the label goes stale.
  nicosVersion =
    let
      d = final.nicosSource.lastModifiedDate or null;
      date =
        if d == null then
          "unknown"
        else
          "${lib.substring 0 4 d}-${lib.substring 4 2 d}-${lib.substring 6 2 d}";
    in
    if release != null then release else "0-unstable-${date}";

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
    src = final.nicosSource;
    version = final.nicosVersion;
  };

  # The pkgs-bound builders (mkSetupPackage, mkNicos, checkSetups, ...). The
  # helpers in lib/services.nix need no package set and are exposed as
  # flake.lib instead.
  nicosLib = final.callPackage ../nix/builders.nix {
    python = final.nicosPython;
  };

  # `import`, not callPackage: this returns a plain attrset of derivations, and
  # callPackage would makeOverridable it -- adding `override` and
  # `overrideDerivation` attributes that then show up in `attrValues` and get
  # handed to things expecting only derivations.
  nicosSetupPackages = import ../pkgs/setup-packages.nix {
    inherit (final) lib nicosLib;
    src = final.nicosSource;
    version = final.nicosVersion;
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
      files=$(grep -rlE "=[[:space:]]*'data(/|')" --include='*.py' nicos_demo/demo || true)
      if [ -z "$files" ]; then
        echo "nicos-nix: nicos_demo no longer uses relative 'data' paths;" >&2
        echo "  drop nicosDemoRebased's postPatch in pkgs/overlay.nix." >&2
        exit 1
      fi
      echo "$files" | xargs sed -i -E "s#=[[:space:]]*'data(/|')#= '/tmp/nicos-demo/data\1#g"
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
