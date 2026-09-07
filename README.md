# nicos-nix

[NICOS](https://forge.frm2.tum.de/nicos/), the MLZ networked instrument control
system, packaged for Nix and NixOS: the core, its setup packages, a NixOS module
for the services, and a Qt client.

```nix
{
  inputs.nicos-nix.url = "github:<you>/nicos-nix";

  # your instrument's setup package, from wherever it lives
  inputs.nicos-mylab = {
    url = "git+ssh://git@git.example.org/lab/nicos_mylab";
    flake = false;
  };
}
```

```nix
services.nicos = {
  enable = true;
  setupPackages = [
    (pkgs.nicosLib.mkSetupPackage {
      name = "nicos_mylab";
      src = inputs.nicos-mylab;
      pythonDeps = ps: [ ps.pyserial ];
    })
  ];
  setupPackage = "nicos_mylab";
  instrument = "20t";
  setupSubdirs = [ "20t" "troja" ];
  services = [ "cache" "poller" "daemon" "elog" "watchdog" "monitor-html" ];
  extras = [ "tango" "keyring" ];
  environment.TANGO_HOST = "tangobox.example.org:10000";
};

users.users.nicos.extraGroups = [ "dialout" ];   # serial hardware
```

`services` is written exactly as in `nicos.conf`, so an existing configuration
transcribes directly. Per-service tuning merges with the list form:

```nix
services.nicos.services = lib.mkMerge [
  [ "cache" "collector-ppms9" ]
  { "collector-ppms9".unit.serviceConfig.Nice = -5; }
];
```

## Running the GUI

```sh
nix run github:<you>/nicos-nix#nicos-gui          # or just `nix run <flake>`
```

With no arguments it opens the instrument chooser, which globs every
`nicos_*/**/guiconfig.py` in its root -- the packaged GUI ships all the setup
packages vendored in the NICOS repo, so that list is populated out of the box.

To go straight to a daemon, or to use a `guiconfig.py` from anywhere on disk:

```sh
nicos-gui user@nicosbox.example.org:1301
nicos-gui -c /srv/nicos/nicos_mylab/20t/guiconfig.py 20t.example.org:1301
nicos-gui -t me@gateway.example.org nicosbox:1301   # through an SSH tunnel
nicos-gui -v ...                                    # view-only
```

For your own instrument, build a GUI with just your setup packages:

```nix
pkgs.nicosLib.mkNicos {
  pname = "nicos-gui";
  extras = [ "gui" ];
  setupPackages = [ myLabSetupPackage ];
  settings = { setup_package = "nicos_mylab"; instrument = "20t"; };
  mainProgram = "nicos-gui";
}
```

or declaratively on a workstation, which also generates a desktop entry per
instrument:

```nix
# NixOS
programs.nicos-gui = {
  enable = true;
  setupPackages = with pkgs.nicosSetupPackages; [ mgml demo ];
  setupPackage = "nicos_mgml";
  instrument = "twenty";
};

# Home Manager -- additionally gives you `servers`, one desktop entry each
programs.nicos-gui.servers."20t" = { host = "nicosbox.mgml.eu"; };
```

Note that the *headless* `.#nicos` package deliberately does **not** ship
`nicos-gui`, `nicos-history` or `designer-nicos`: without the `gui` extra those
can only fail at import, so shipping them would be a trap. `nicos-monitor` is
still there, because the same binary serves the headless HTML monitor.

Other runnable apps:

```sh
nix run <flake>#demo           # nicos-aio: a whole demo instrument in one process
nix run <flake>#nicos-client   # the text client
```

## How it works

NICOS derives `config.nicos_root` from the location of its own `configmod.py`,
and reads `nicos.conf` from `<nicos_root>/nicos.conf`. No environment variable
relocates either. So instead of patching that, this flake reproduces upstream's
own layout in the store: a derivation whose `$out` *is* a valid NICOS root,
containing `nicos/`, your `nicos_<facility>/` packages, `bin/`, and a generated
`nicos.conf`.

Three details make that work, and all three are load-bearing:

- **`__file__` is never `realpath`'d by the import system**, so a package
  reached through `$out` reports `$out/nicos/__init__.py` and `nicos_root`
  is `$out`, whatever lies underneath. The build asserts this.
- **The root is deep-linked with `lndir`**, not top-level directory symlinks.
  The GUI's instrument picker uses `Path(nicos_root).rglob('guiconfig.py')`,
  and Python 3.13's pathlib does not recurse into symlinked directories, so
  directory symlinks would make it silently find nothing.
- **`bin/*` are real files**, because the poller, daemon and watchdog respawn
  `<root>/bin/nicos-{poller,simulate,script}` as `[sys.executable, script]` --
  Python *reads* those files, so a shell wrapper there would be a `SyntaxError`.

## Relative paths in setups

NICOS resolves `FlatfileCacheDatabase.storepath`, `Exp.dataroot` and friends
with `path.join(config.nicos_root, ...)`. Writing them relative is the norm
upstream -- every vendored facility package does it, `nicos_virt_mlz` in 42
places -- and it **cannot work against a read-only store root**. You get a
`PermissionError` naming a `/nix/store` path, at runtime rather than at startup.

Two ways out:

1. Use absolute paths in your own setups (what MGML already does:
   `storepath = '/data/cache'`). Point them at `services.nicos.dataDir` or an
   entry of `services.nicos.extraDirectories`.
2. Run from a writable checkout:

```nix
services.nicos.root = {
  mode = "mutable";
  path = "/srv/nicos";
};
```

`nicos_root` then *is* `/srv/nicos`. Nix still supplies the interpreter, the
wrappers, the units and (unless you set `manageNicosConf = false`)
`nicos.conf`; the code is yours. Nix-built setup packages still work alongside
a hand-managed core -- in this mode they go on `[environment] PYTHONPATH`
instead of being linked into the root, so a pinned `nicos_mgml` on top of a
checked-out core is a supported combination.

One gotcha, if you use `root.seed` to populate the directory from
`nicos-unwrapped`: that tree is precompiled with `--invalidation-mode
unchecked-hash`, which Python *never* revalidates, so leftover `__pycache__`
would make your edits silently have no effect. The seed script strips it; a
plain `git clone` never has the problem.

There is also a lighter-weight middle ground that keeps NICOS core pinned and
makes only setups editable:

```nix
services.nicos.mutableSetupPackages = [ "/srv/nicos-setups" ];
```

## What this flake patches, and why

One source patch and two environment-level fixes. The environment ones are
deliberately *not* source patches, so they apply equally to a mutable checkout:

- **`ctypes.util.find_library` cannot work on NixOS** -- no `ldconfig` cache, no
  compiler at runtime -- and returns `None`. `nicos/clients/cli/__init__.py`
  does `ctypes.cdll[find_library('readline')]` at module level, so `nicos-client`
  dies with a `TypeError` on import; `nicos/guisupport/qt.py` silently skips its
  libGL preload. `LD_LIBRARY_PATH` does not help, because `find_library` never
  gets far enough to consult it. Fixed generically in `nix/nicos_nix_fixes.py`,
  loaded through a `.pth` file (nixpkgs' python already ships a
  `sitecustomize.py`, so that name collides).
- **nixpkgs' `pyqt6` has no `QtDesigner`**, which `nicos/guisupport/qt.py`
  imports unconditionally. The only consumer of a QtDesigner symbol in the whole
  tree is `nicos/guisupport/widgetplugin.py`, which Qt Designer loads itself, so
  an empty stub module is supplied.
- **The version is frozen at build time.** `gitversion.get_nicos_version()`
  shells out to `git describe` before falling back to `RELEASE-VERSION`, costing
  a failed fork on every `import nicos`. Not applied to mutable roots, which
  have real git metadata -- there, `git` is put on the unit's `PATH` instead,
  because with neither git nor `RELEASE-VERSION` `import nicos` raises outright.

## Layout

```
flake.nix                 flake-parts; inputs nixpkgs + nicos-src (flake = false)
nix/python.nix            the python313 pin (NICOS supports <= 3.13; nixpkgs is on 3.14)
nix/lib.nix               mkSetupPackage, mkNicosRoot, mkNicosEnv, mkNicos
nix/nicos_nix_fixes.py    the two environment-level fixes
lib/services.nix          pure helpers: unitNameFor, splitServiceName, ...
pkgs/nicos/               nicos-unwrapped + the dependency table
pkgs/setup-packages.nix   the setup packages vendored in the NICOS repo
pkgs/python/              lttb, nicos-pyctl, gr, mlzlog, frappy-core
                          -- the deps nixpkgs lacks
pkgs/gr-framework/        the GR plotting runtime, built from source
nixos/                    services.nicos and programs.nicos-gui
home/                     programs.nicos-gui for Home Manager
tests/{eval,demo}.nix     eval-only unit assertions; the end-to-end VM test
examples/mgml.nix         a real instrument configuration
```

## Checks

```
nix flake check
nix build .#checks.x86_64-linux.eval           # unit-generation rules, seconds, no VM
nix build .#checks.x86_64-linux.import-sweep   # every core module imports
nix build .#checks.x86_64-linux.gui-offscreen  # GR, QtDesigner stub, WebEngine, QScintilla
nix build .#checks.x86_64-linux.vm-demo        # services under systemd, end to end
```

`vm-demo` needs working KVM to finish in reasonable time. If your builder cannot
open `/dev/kvm` -- check that the `nixbld` users are in the `kvm` group -- QEMU
falls back to software emulation and the VM takes minutes per boot.

## Status

Working and verified: the packages, the setup-package builder, the NixOS module,
the GR framework built from source, the Qt6 GUI, and the end-to-end service test
(cache + poller + daemon under systemd, driven by a real `NicosClient`).

The `secop` extra works too: `frappy-core` and its missing dependency `mlzlog`
are packaged here, and `nicos.devices.secop` imports against them.

EPICS (`pyepics`/`caproto`/`p4p` plus EPICS base) is deferred: nixpkgs has none
of it, and it would roughly double the C-packaging work. `extras.epics` is not
declared, so asking for it is an error rather than a silent no-op.
