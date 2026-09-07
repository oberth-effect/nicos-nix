# The composition layer.
#
# mkSetupPackage  a nicos_<facility> directory -> a derivation
# mkNicosRoot     core + setup packages + nicos.conf -> a valid NICOS root
# mkNicosEnv      a root path -> the user-facing bin/nicos-* wrappers
# mkNicos         all of the above, wired together
{
  lib,
  stdenvNoCC,
  runCommand,
  lndir,
  makeBinaryWrapper,
  formats,
  python,
  nicos-unwrapped,
  nicosSitecustomize,
  libglvnd,
  readline,
  qt6,
  qt6Packages,
}:

let
  tomlFormat = formats.toml { };

  # The executables NICOS ships in bin/. Deliberately a static list rather
  # than builtins.readDir "${nicos}/bin": reading the directory would be
  # import-from-derivation, forcing nicos-unwrapped to be *built* during
  # evaluation -- which breaks `nix flake show`, cross-system evaluation and
  # any pure-eval consumer. mkNicosRoot asserts that this list still matches
  # the source tree, so upstream adding a binary is a build error rather than
  # a silently missing wrapper.
  nicosBinNames = [
    "designer-nicos"
    "nicos-aio"
    "nicos-cache"
    "nicos-client"
    "nicos-collector"
    "nicos-daemon"
    "nicos-demo"
    "nicos-elog"
    "nicos-grep-cache"
    "nicos-gui"
    "nicos-history"
    "nicos-keystore"
    "nicos-monitor"
    "nicos-poller"
    "nicos-script"
    "nicos-simulate"
    "nicos-watchdog"
  ];

  # Binaries that cannot work without the `gui` extra. A headless build omits
  # their wrappers rather than shipping ones that fail with
  # `ModuleNotFoundError: No module named 'PyQt5'` -- the root still contains
  # the scripts, so nothing else changes.
  #
  # nicos-monitor is deliberately NOT here: the same binary serves both the
  # headless HTML monitor and the Qt one, chosen by the setup file.
  guiOnlyBinNames = [
    "designer-nicos"
    "nicos-gui"
    "nicos-history"
  ];

  # NICOS joins these onto nicos_root, which is a read-only store path, so a
  # relative value would try to write into the store.
  assertAbsolute =
    key: value:
    lib.throwIf (!lib.hasPrefix "/" (toString value)) ''
      nicos-nix: nicos.conf key `${key}` = "${toString value}" is relative.
      NICOS resolves it against nicos_root, which here is a read-only
      /nix/store path. Use an absolute path (e.g. /run/nicos, /var/log/nicos).
    '' value;
in
rec {

  # A setup package needs no setup.py: NICOS finds it with
  # importlib.import_module(setup_package), so a bare directory of setups and
  # device classes is enough -- which is what out-of-tree instrument repos
  # actually look like.
  mkSetupPackage =
    {
      name,
      src,
      version ? "unstable",
      # Path within `src` holding the package directory; "." when `src` already
      # *is* that directory. Explicit rather than auto-detected: a wrong guess
      # must fail the build, not silently yield an empty instrument picker.
      subdir ? name,
      pythonDeps ? (_ps: [ ]),
      postPatch ? "",
      patches ? [ ],
      meta ? { },
    }:
    stdenvNoCC.mkDerivation {
      pname = name;
      inherit
        version
        src
        patches
        postPatch
        ;

      strictDeps = true;
      nativeBuildInputs = [ python ];
      dontConfigure = true;
      dontBuild = true;

      installPhase = ''
        runHook preInstall
        if [ ! -d ${lib.escapeShellArg subdir} ]; then
          echo "nicos-nix: mkSetupPackage ${name}: '${subdir}' is not a directory in src" >&2
          exit 1
        fi
        mkdir -p "$out/${name}"
        cp -a ${lib.escapeShellArg subdir}/. "$out/${name}"
        runHook postInstall
      '';

      postFixup = ''
        if [ ! -f "$out/${name}/__init__.py" ]; then
          echo "nicos-nix: $out/${name}/__init__.py is missing." >&2
          echo "  '${name}' must be an importable package, because NICOS loads" >&2
          echo "  setup_package with importlib.import_module. Check subdir." >&2
          exit 1
        fi
        # devices/ modules ARE imported; setups/ files are exec'd, so skip them.
        # Tolerant: facility trees legitimately carry broken example files.
        ${python.pythonOnBuildForHost.interpreter} -m compileall \
          -q -f -j "$NIX_BUILD_CORES" --invalidation-mode unchecked-hash \
          -x '.*/(setups|testscripts|template)/.*' "$out/${name}" || true
      '';

      passthru = {
        setupPackageName = name;
        inherit pythonDeps;
      };

      meta = {
        description = "NICOS setup package ${name}";
        platforms = lib.platforms.linux;
      }
      // meta;
    };

  mkPythonEnv =
    {
      nicos ? nicos-unwrapped,
      setupPackages ? [ ],
      extras ? [ ],
      extraPythonPackages ? (_ps: [ ]),
    }:
    let
      inherit (nicos.passthru) dependencies optional-dependencies;
      known = lib.attrNames optional-dependencies;
      unknown = lib.subtractLists known extras;
    in
    lib.throwIf (unknown != [ ])
      ''
        nicos-nix: unknown extras: ${lib.concatStringsSep ", " unknown}
        known extras: ${lib.concatStringsSep ", " known}
      ''
      (
        python.withPackages (
          ps:
          dependencies
          ++ lib.concatLists (lib.attrVals extras optional-dependencies)
          ++ lib.concatMap (sp: sp.pythonDeps ps) setupPackages
          ++ extraPythonPackages ps
          ++ [ nicosSitecustomize ]
        )
      );

  # Linux resolves exactly one `#!` level, and whether a withPackages env's
  # bin/python3 is an ELF binary-wrapper or a shell script is a nixpkgs
  # implementation detail that has flip-flopped. makeBinaryWrapper always
  # produces an ELF executable, so it is always legal in a shebang.
  mkPythonShim =
    pythonEnv:
    runCommand "nicos-python-${python.pythonVersion}"
      {
        nativeBuildInputs = [ makeBinaryWrapper ];
        passthru = { inherit pythonEnv; };
      }
      ''
        mkdir -p $out/bin
        makeBinaryWrapper ${pythonEnv}/bin/python3 $out/bin/python3 \
          --set PYTHONNOUSERSITE 1
        ln -s python3 $out/bin/python
      '';

  mkNicosConf =
    {
      settings ? { },
      environment ? { },
    }:
    let
      checked =
        settings
        // lib.optionalAttrs (settings ? pid_path) {
          pid_path = assertAbsolute "pid_path" settings.pid_path;
        }
        // lib.optionalAttrs (settings ? logging_path) {
          logging_path = assertAbsolute "logging_path" settings.logging_path;
        };
    in
    tomlFormat.generate "nicos.conf" (
      { nicos = checked; } // lib.optionalAttrs (environment != { }) { inherit environment; }
    );

  # $out is a valid NICOS root: config.nicos_root resolves to it, and
  # <nicos_root>/nicos.conf exists.
  mkNicosRoot =
    {
      pname ? "nicos",
      nicos ? nicos-unwrapped,
      setupPackages ? [ ],
      settings ? { },
      environment ? { },
      pythonShim,
    }:
    let
      nicosConf = mkNicosConf { inherit settings environment; };
      # The nicos_root self-test needs an importable setup package, because
      # nicos/_vendor/gitversion.py calls config.apply() at import time.
      canSelfTest = setupPackages != [ ] && (settings.setup_package or null) != null;
    in
    stdenvNoCC.mkDerivation {
      pname = "${pname}-root";
      inherit (nicos) version;

      dontUnpack = true;
      strictDeps = true;
      nativeBuildInputs = [ lndir ];

      buildCommand = ''
        mkdir -p "$out"

        # DEEP link: real directories, symlinked leaf files.
        #
        # Top-level directory symlinks would break
        #   nicos/clients/gui/dialogs/instr_select.py:
        #     Path(config.nicos_root).rglob('guiconfig.py')
        # because pathlib's `**` does not recurse into symlinked directories on
        # Python 3.13 (recurse_symlinks defaults to False), so the GUI's
        # instrument picker would silently find nothing.
        lndir -silent ${nicos} "$out"
        ${lib.concatMapStringsSep "\n" (sp: ''lndir -silent ${sp} "$out"'') setupPackages}

        # bin/ must be REAL files, for two independent reasons:
        #  * nicos_root is derived from realpath(__file__) of the script;
        #  * the poller, daemon and watchdog respawn $out/bin/nicos-{poller,
        #    simulate,script} as [sys.executable, script] -- Python *reads* the
        #    file, so a shell wrapper there would be a SyntaxError.
        rm -rf "$out/bin"
        mkdir -p "$out/bin"
        cp --no-preserve=mode ${nicos}/bin/* "$out/bin/"
        for f in "$out"/bin/*; do
          if head -c2 "$f" | grep -q '^#!'; then
            sed -i "1s|^#!.*|#!${pythonShim}/bin/python3|" "$f"
          else
            sed -i "1i #!${pythonShim}/bin/python3" "$f"
          fi
          chmod 555 "$f"
        done

        install -m444 ${nicosConf} "$out/nicos.conf"

        ##################### postconditions #####################
        test -f "$out/nicos/configmod.py"
        test -f "$out/nicos/RELEASE-VERSION"
        test -d "$out/template"
        test -d "$out/nicostools"
        # Every executable we generate a wrapper for must exist, and the source
        # tree must ship nothing we would silently drop.
        expected=$(for b in ${lib.escapeShellArgs nicosBinNames}; do echo "$b"; done | sort)
        actual=$(cd "$out/bin" && ls | sort)
        if [ "$expected" != "$actual" ]; then
          echo "nicos-nix: bin/ does not match nix/lib.nix's nicosBinNames." >&2
          echo "  only in nicosBinNames:" >&2
          comm -23 <(echo "$expected") <(echo "$actual") | sed 's/^/    /' >&2
          echo "  only in the source tree:" >&2
          comm -13 <(echo "$expected") <(echo "$actual") | sed 's/^/    /' >&2
          exit 1
        fi
        ${lib.concatMapStringsSep "\n" (
          sp: ''test -f "$out/${sp.setupPackageName}/__init__.py"''
        ) setupPackages}

        # A `nicos` in site-packages would silently relocate nicos_root to the
        # env, where there is no nicos.conf -- a working-looking NICOS aimed at
        # the wrong facility.
        if [ -e "${pythonShim.pythonEnv}/${python.sitePackages}/nicos/configmod.py" ]; then
          echo "nicos-nix: the composed interpreter env contains a 'nicos'" >&2
          echo "  package in site-packages; nicos_root would be ambiguous." >&2
          exit 1
        fi
      ''
      + lib.optionalString canSelfTest ''
        # The assertion that actually proves the architecture works.
        export HOME="$TMPDIR"
        got=$(${pythonShim}/bin/python3 -c "import sys; sys.path.insert(0, '$out'); from nicos import config; print(config.nicos_root)")
        if [ "$got" != "$out" ]; then
          echo "nicos-nix: config.nicos_root is '$got', expected '$out'" >&2
          exit 1
        fi
        echo "nicos-nix: verified config.nicos_root == $out"
      '';

      passthru = { inherit pythonShim setupPackages; };

      meta = {
        description = "NICOS root (${pname})";
        platforms = lib.platforms.linux;
      };
    };

  # `rootPath` is a store path in the default (immutable) mode and a plain
  # string path when running from a writable checkout. It is resolved at
  # runtime, so this builds fine before the checkout exists.
  mkNicosEnv =
    {
      pname ? "nicos",
      version,
      rootPath,
      pythonShim,
      binNames ? nicosBinNames,
      withGui ? false,
      extraWrapperEnv ? { },
      mainProgram ? null,
    }:
    let
      envArgs = lib.concatLists (
        lib.mapAttrsToList (k: v: [
          "--set"
          k
          (toString v)
        ]) extraWrapperEnv
      );
      # ctypes.util.find_library cannot work on NixOS (no ldconfig cache, no
      # compiler at runtime), so nix/nicos_nix_fixes.py gives it these
      # directories to search instead. readline is needed by nicos-client at
      # import time; libGL by the Qt GUI's RTLD_GLOBAL preload.
      libDirs = [ (lib.getLib readline) ] ++ lib.optional withGui (lib.getLib libglvnd);
      guiArgs = [
        "--set"
        "NICOS_LIBRARY_PATH"
        (lib.makeLibraryPath libDirs)
      ]
      ++ lib.optionals withGui [
        "--set"
        "NICOS_QT"
        "6"
      ];
    in
    stdenvNoCC.mkDerivation {
      inherit pname version;
      dontUnpack = true;
      strictDeps = true;

      nativeBuildInputs = [
        makeBinaryWrapper
      ]
      ++ lib.optional withGui qt6Packages.wrapQtAppsHook;

      # pyqt6 sets dontWrapQtApps on itself and does NOT propagate qtbase, so
      # these must be named explicitly or qtWrapperArgs comes out empty and the
      # GUI dies with "could not find the Qt platform plugin".
      buildInputs = lib.optionals withGui [
        qt6.qtbase
        qt6.qtsvg
        qt6.qtwayland
      ];

      # Every wrapper is built by hand below; the hook's automatic pass only
      # handles ELF files anyway and must not double-wrap.
      dontWrapQtApps = true;

      installPhase = ''
        runHook preInstall
        mkdir -p "$out/bin"
      ''
      + lib.concatMapStringsSep "\n" (n: ''
        makeBinaryWrapper ${pythonShim}/bin/python3 "$out/bin/${n}" \
          --add-flags ${lib.escapeShellArg "${rootPath}/bin/${n}"} \
          ${lib.escapeShellArgs (envArgs ++ guiArgs)} \
          ${lib.optionalString withGui ''"''${qtWrapperArgs[@]}"''}
      '') binNames
      + ''

        # `import nicos` with a *correct* nicos_root, for scripting and tests.
        makeBinaryWrapper ${pythonShim}/bin/python3 "$out/bin/nicos-python" \
          --prefix PYTHONPATH : ${lib.escapeShellArg rootPath} \
          ${lib.escapeShellArgs (envArgs ++ guiArgs)}
        runHook postInstall
      '';

      meta = {
        description = "NICOS instrument control system";
        homepage = "https://forge.frm2.tum.de/nicos/";
        license = lib.licenses.gpl2Plus;
        platforms = lib.platforms.linux;
      }
      // lib.optionalAttrs (mainProgram != null) { inherit mainProgram; };
    };

  ## ------------------------------------------------------------------ ##
  ## Setup validation                                                   ##
  ## ------------------------------------------------------------------ ##

  # Validate a composed root's setups at build time, so a mistake fails
  # `nixos-rebuild` instead of the instrument.
  #
  # Two levels, because they cost wildly different amounts:
  #
  #  "names" -- assert that every special setup implied by the `services` list
  #     exists. Cheap, no extra closure. This catches the failure the whole
  #     idea was for: a typo'd `-S` name (`collector-ppms-9`) yields a unit
  #     that starts, fails to find its setup, exits non-zero, and -- with
  #     Restart=on-abnormal -- does *not* restart. A silently dead collector.
  #
  #  "full" -- additionally run upstream's tools/check-setups, which validates
  #     device classes, parameters and guiconfig files. Note the cost:
  #     nicostools/setupchecker imports nicos.clients.gui.config, which imports
  #     nicos.guisupport.qt, so this needs a Qt binding and pulls Qt and GR
  #     into the *build* closure even for a headless instrument. That is why it
  #     is not the default.
  checkSetups =
    {
      # the package whose root is being validated
      nicos,
      # special setup names implied by the services list, e.g. [ "monitor-html" ]
      setupNames ? [ ],
      level ? "names",
      extraArgs ? [ ],
    }:
    let
      # For "full" we need an interpreter that can import Qt. Built here rather
      # than reusing the runtime env, so the Qt closure stays a build-time
      # dependency of the check and never reaches the service.
      guiEnv = mkPythonEnv {
        nicos = nicos.passthru.nicosUnwrapped or nicos-unwrapped;
        setupPackages = nicos.passthru.setupPackages or [ ];
        extras = [ "gui" ];
      };
      guiShim = mkPythonShim guiEnv;
    in
    runCommand "nicos-check-setups"
      {
        passthru = { inherit level setupNames; };
      }
      (
        ''
          export HOME="$TMPDIR"
          root=${nicos.passthru.root}

          # Ask NICOS itself where the setups live, rather than reimplementing
          # findSetupRoots: setup_subdirs, the instrument's own nicos.conf and
          # the setup_package import all have to agree.
          dirs=$(${nicos}/bin/nicos-python -c "
          import os
          from nicos import config
          print(' '.join(os.path.join(config.setup_package_path, s, 'setups')
                         for s in config.setup_subdirs))")
          echo "nicos-nix: setup roots: $dirs"

          for want in ${lib.escapeShellArgs setupNames}; do
            found=
            for d in $dirs; do
              if [ -f "$d/special/$want.py" ] || [ -f "$d/$want.py" ]; then found=1; break; fi
            done
            if [ -z "$found" ]; then
              echo "nicos-nix: services requires the special setup '$want', but" >&2
              echo "  no '$want.py' exists under any of:" >&2
              for d in $dirs; do echo "    $d/special/" >&2; done
              echo "  A service named '<proc>-<name>' loads setups/special/<proc>-<name>.py." >&2
              exit 1
            fi
            echo "nicos-nix: ok, special setup '$want' exists"
          done
        ''
        + lib.optionalString (level == "full") ''
          echo "nicos-nix: running upstream tools/check-setups"
          ${guiShim}/bin/python3 "$root/tools/check-setups"           ${lib.escapeShellArgs extraArgs} $dirs
        ''
        + ''
          touch $out
        ''
      );

  mkNicos =
    {
      pname ? "nicos",
      nicos ? nicos-unwrapped,
      setupPackages ? [ ],
      extras ? [ ],
      extraPythonPackages ? (_ps: [ ]),
      settings ? { },
      environment ? { },
      extraWrapperEnv ? { },
      mainProgram ? null,
      # "store": the root is a derivation built here.
      # "mutable": the root is `rootPath`, a checkout we do not manage.
      mode ? "store",
      rootPath ? null,
    }:
    let
      withGui = lib.elem "gui" extras;
      mutableMode = mode == "mutable";
      pythonEnv = mkPythonEnv {
        inherit
          nicos
          setupPackages
          extras
          extraPythonPackages
          ;
      };
      pythonShim = mkPythonShim pythonEnv;

      # In mutable mode the setup packages cannot be linked into a root we do
      # not own, so make them importable instead. NICOS applies [environment]
      # PYTHONPATH to sys.path *before* importlib.import_module(setup_package),
      # so this resolves identically -- and it means a Nix-pinned nicos_mgml can
      # sit on top of a hand-checked-out core, which is what you actually want
      # while debugging core.
      environment' =
        if mutableMode && setupPackages != [ ] then
          environment
          // {
            PYTHONPATH = lib.concatStringsSep ":" (
              map toString setupPackages ++ lib.optional (environment ? PYTHONPATH) environment.PYTHONPATH
            );
          }
        else
          environment;

      storeRoot = mkNicosRoot {
        inherit
          pname
          nicos
          setupPackages
          settings
          pythonShim
          ;
        environment = environment';
      };

      effectiveRoot = if mutableMode then toString rootPath else "${storeRoot}";

      binNames = if withGui then nicosBinNames else lib.subtractLists guiOnlyBinNames nicosBinNames;

    in
    lib.throwIf (mode == "mutable" && rootPath == null)
      ''nicos-nix: mkNicos with mode = "mutable" requires `rootPath`.''
      (
        (mkNicosEnv {
          inherit
            pname
            pythonShim
            binNames
            withGui
            extraWrapperEnv
            mainProgram
            ;
          inherit (nicos) version;
          rootPath = effectiveRoot;
        }).overrideAttrs
          (old: {
            passthru = (old.passthru or { }) // {
              inherit pythonEnv pythonShim setupPackages;
              # so checkSetups can build a Qt-capable env from the same source
              nicosUnwrapped = nicos;
              root = if mutableMode then toString rootPath else storeRoot;
              nicosConf = mkNicosConf {
                inherit settings;
                environment = environment';
              };
            };
          })
      );
}
