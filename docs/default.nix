# The documentation site: the README split into one chapter per section, the
# option reference for services.nicos and programs.nicos-gui generated from
# the modules themselves, and the two examples.
#
#   nix build .#docs && xdg-open result/index.html
#
# .github/workflows/docs.yml publishes it to GitHub Pages. The README stays
# the single source for the guide; nothing here is written twice.
{
  lib,
  stdenvNoCC,
  mdbook,
  nixosOptionsDoc,
  pkgs,
  self,
  nixpkgs,
}:
let
  repo = "https://github.com/oberth-effect/nicos-nix";

  # Evaluate the module inside a real NixOS, so that everything it declares
  # is present, then document only our subtrees. Nothing is built: the option
  # defaults all carry a defaultText.
  nixos =
    (nixpkgs.lib.nixosSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [
        self.nixosModules.nicos
        {
          nixpkgs.pkgs = pkgs;
          system.stateVersion = "25.05";
        }
      ];
    }).options;

  optionsMarkdown =
    options:
    (nixosOptionsDoc {
      inherit options;
      warningsAreErrors = true;
      # Declarations come out as store paths; turn them into source links.
      transformOptions =
        opt:
        opt
        // {
          declarations = map (
            d:
            let
              rel = lib.removePrefix "${self}/" (toString d);
              # A module imported as a directory is recorded as that
              # directory; link to the file GitHub would show.
              file = if lib.hasSuffix ".nix" rel then rel else "${rel}/default.nix";
            in
            {
              name = file;
              url = "${repo}/blob/master/${file}";
            }
          ) opt.declarations;
        };
    }).optionsCommonMark;

  servicesMd = optionsMarkdown { services.nicos = nixos.services.nicos; };
  guiMd = optionsMarkdown { programs.nicos-gui = nixos.programs.nicos-gui; };

  # Only what the book reads, so an unrelated edit does not rebuild it.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../README.md
      ../examples
      ./book.toml
    ];
  };
in
stdenvNoCC.mkDerivation {
  pname = "nicos-nix-docs";
  version = self.shortRev or "dirty";
  inherit src;

  nativeBuildInputs = [ mdbook ];

  buildPhase = ''
    runHook preBuild
    mkdir -p book/src
    cp docs/book.toml book/

    # The README is the guide. One chapter per `## ` section keeps the
    # sidebar useful; the text before the first section is the introduction.
    awk -v dir=book/src '
      function slug(s) {
        s = tolower(s); gsub(/[^a-z0-9]+/, "-", s); gsub(/^-|-$/, "", s); return s
      }
      BEGIN { file = dir "/introduction.md"; n = 0 }
      /^## / {
        n++
        title = substr($0, 4)
        name = sprintf("%02d-%s.md", n, slug(title))
        file = dir "/" name
        print "# " title > file
        printf "- [%s](%s)\n", title, name > (dir "/chapters.txt")
        next
      }
      { print > file }
    ' README.md

    {
      echo "# services.nicos"
      echo
      echo "The NixOS module. Generated from the module's option declarations;"
      echo "every entry links to the file that declares it."
      echo
      cat ${servicesMd}
    } > book/src/options-services-nicos.md

    {
      echo "# programs.nicos-gui"
      echo
      echo "The Qt client. The NixOS and the Home Manager module share this"
      echo "option set, so it is documented once; under Home Manager the"
      echo "generated desktop entries land in \`xdg.desktopEntries\`."
      echo
      cat ${guiMd}
    } > book/src/options-programs-nicos-gui.md

    example() {
      {
        echo "# $2"
        echo
        echo "\`$1\` in the repository."
        echo
        echo '```nix'
        cat "$1"
        echo '```'
      } > "book/src/$3"
    }
    example examples/mgml.nix "Example: an instrument host" example-mgml.md
    example examples/mylab-flake.nix "Example: a setup package repository" example-mylab-flake.md

    {
      echo "# Summary"
      echo
      echo "- [Introduction](introduction.md)"
      cat book/src/chapters.txt
      echo
      echo "# Reference"
      echo
      echo "- [services.nicos](options-services-nicos.md)"
      echo "- [programs.nicos-gui](options-programs-nicos-gui.md)"
      echo "- [Example: an instrument host](example-mgml.md)"
      echo "- [Example: a setup package repository](example-mylab-flake.md)"
    } > book/src/SUMMARY.md
    rm book/src/chapters.txt
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mdbook build book --dest-dir "$out"
    runHook postInstall
  '';

  meta.description = "The nicos-nix documentation site";
}
