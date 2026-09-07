"""nicos-nix environment fixes.

Two nixpkgs-specific problems that NICOS cannot be expected to know about.
They live here, in the Python environment, rather than in a source patch, so
that they apply equally to the immutable /nix/store root and to a mutable
checkout (services.nicos.root.mode = "mutable"), where a substituteInPlace
could never reach.

Loaded through a .pth file rather than sitecustomize.py: nixpkgs' own python3
already ships a sitecustomize.py in site-packages, so that name collides in
python.buildEnv. A .pth with a unique name cannot.

Both fixes are lazy -- nothing here imports Qt or opens a shared library at
interpreter startup, so the headless services (cache, poller, elog, watchdog,
collector) pay nothing.
"""

import importlib.abc
import importlib.machinery
import os
import sys

# ---------------------------------------------------------------------------
# 1. ctypes.util.find_library
#
# On NixOS the stock implementation cannot find anything: it shells out to
# `ldconfig -p`, `gcc` or `objdump`, none of which exist at runtime, and there
# is no /etc/ld.so.cache. It therefore returns None, and NICOS calls it in two
# places that react badly:
#
#   nicos/clients/cli/__init__.py:67
#       librl = ctypes.cdll[ctypes.util.find_library('readline')]
#   -> ctypes.cdll[None] raises TypeError at import, so the whole text client
#      is dead rather than merely degraded.
#
#   nicos/guisupport/qt.py:123
#       libGL = ctypes.util.find_library('GL')
#       if libGL: ctypes.CDLL(libGL, mode=ctypes.RTLD_GLOBAL)
#   -> silently skips a preload that works around black/white QtWebEngine
#      windows.
#
# Note that LD_LIBRARY_PATH does not help either case: find_library never gets
# far enough to consult the loader.
#
# So give it a fallback that searches the directories the Nix wrapper told us
# about, and return an absolute path -- which is what CDLL wants on a system
# without a loader cache. Fixing the function rather than each call site means
# NICOS's own logic then runs exactly as upstream intended.
# ---------------------------------------------------------------------------

_LIB_DIRS = [p for p in os.environ.get("NICOS_LIBRARY_PATH", "").split(os.pathsep) if p]

if _LIB_DIRS:
    import ctypes.util as _ctypes_util

    _stock_find_library = _ctypes_util.find_library

    def _find_library(name):
        found = _stock_find_library(name)
        if found:
            return found

        import glob

        # Unversioned first (a dev output), then the highest versioned soname.
        for pattern in ("lib%s.so" % name, "lib%s.so.*" % name, "%s.so" % name):
            for directory in _LIB_DIRS:
                hits = sorted(glob.glob(os.path.join(directory, pattern)))
                if hits:
                    return hits[-1]
        return None

    _find_library.__doc__ = _stock_find_library.__doc__
    _ctypes_util.find_library = _find_library


# ---------------------------------------------------------------------------
# 2. QtDesigner
#
# nicos/guisupport/qt.py does an unconditional `from PyQt6.QtDesigner import *`
# (and the PyQt5 equivalent), but nixpkgs' pyqt6 never builds the QtDesigner
# bindings -- unlike pyqt5, which has a `withTools` flag.
#
# The only consumer of a QtDesigner symbol in the entire NICOS tree is
# nicos/guisupport/widgetplugin.py (QPyDesignerCustomWidgetPlugin), which Qt
# Designer imports itself and the GUI never touches. So an empty module makes
# the wildcard import bind nothing, which is exactly right; the only casualty
# is custom NICOS widgets inside designer-nicos.
#
# Implemented as a meta-path finder *appended* to sys.meta_path, so it is
# consulted after the real PathFinder: where the genuine extension module
# exists, this never runs.
# ---------------------------------------------------------------------------

_QTDESIGNER_MODULES = frozenset(["PyQt6.QtDesigner", "PyQt5.QtDesigner"])


class _StubLoader(importlib.abc.Loader):
    def create_module(self, spec):
        return None  # use the default module object

    def exec_module(self, module):
        module.__nicos_nix_stub__ = True


class _QtDesignerStubFinder(importlib.abc.MetaPathFinder):
    """Provide an empty PyQt{5,6}.QtDesigner when the real one is absent."""

    def find_spec(self, fullname, path=None, target=None):
        if fullname not in _QTDESIGNER_MODULES:
            return None
        return importlib.machinery.ModuleSpec(fullname, _StubLoader())


if not any(isinstance(f, _QtDesignerStubFinder) for f in sys.meta_path):
    sys.meta_path.append(_QtDesignerStubFinder())
