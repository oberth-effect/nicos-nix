"""Import every module in the NICOS core tree and classify the failures.

The point is to separate three things that look alike:

  * a module needing an optional dependency we deliberately did not install
    (pytango, gr, epics, PyQt6 in a headless env, ...). Expected, reported.

  * a module that cannot import at all without a native dependency nixpkgs
    does not carry, and which fails with something messier than a clean
    ModuleNotFoundError. Explicitly allowlisted below, with a reason.

  * anything else -- a SyntaxError, or an ImportError/TypeError from a
    dependency that moved under us. That is a real regression, and the reason
    this check exists: it is how we find out empirically whether NICOS works
    against the numpy (and everything else) the pinned nixpkgs ships.
"""

import importlib
import pkgutil
import sys
import traceback

root = sys.argv[1]
sys.path.insert(0, root)

import nicos  # noqa: E402  (must follow the sys.path insert)

FIRST_PARTY = ("nicos", "nicostools")

# Module prefixes that cannot import in this environment for a known,
# accepted reason. Keep the reasons here: an entry without one is a bug
# being swept under the rug.
KNOWN_UNAVAILABLE = {
    "nicos.devices.vendor.caress": (
        "needs omniORBpy, which is not in nixpkgs. Upstream latent bug: "
        "core.py catches the ImportError but then leaves CARESS unbound, so "
        "base.py's `from ...core import CARESS` fails rather than degrading."
    ),
    "nicos.devices.vendor.qmesydaq.caress": (
        "same as nicos.devices.vendor.caress (imports it)"
    ),
}

optional = {}
known = {}
hard = []
classified = set()


def classify(name, exc):
    # walk_packages' onerror fires for a package that fails to import, and the
    # loop below then tries the same name again: count it once.
    if name in classified:
        return
    classified.add(name)
    for prefix, reason in KNOWN_UNAVAILABLE.items():
        if name == prefix or name.startswith(prefix + "."):
            known.setdefault(prefix, []).append(name)
            return
    # A missing non-first-party module means an optional dependency.
    if isinstance(exc, ModuleNotFoundError) and exc.name:
        top = exc.name.split(".")[0]
        if top not in FIRST_PARTY and not top.startswith("nicos_"):
            optional.setdefault(top, []).append(name)
            return
    hard.append((name, exc))


def onerror(name):
    classify(name, sys.exc_info()[1])


count = 0
for info in pkgutil.walk_packages(nicos.__path__, prefix="nicos.", onerror=onerror):
    count += 1
    try:
        importlib.import_module(info.name)
    except Exception as exc:  # noqa: BLE001 - classifying everything is the job
        classify(info.name, exc)

print(f"swept {count} modules under {root}")

if optional:
    print("\nskipped, optional dependency not installed:")
    for dep in sorted(optional):
        mods = optional[dep]
        print(f"  {dep:<22} {len(mods):>3} module(s)   e.g. {mods[0]}")

if known:
    print("\nskipped, known unavailable:")
    for prefix in sorted(known):
        print(f"  {prefix}")
        print(f"      {KNOWN_UNAVAILABLE[prefix]}")

if hard:
    print(f"\n{len(hard)} HARD failure(s):", file=sys.stderr)
    for name, exc in hard:
        print(f"\n=== {name}", file=sys.stderr)
        traceback.print_exception(type(exc), exc, exc.__traceback__, limit=6)
    sys.exit(1)

print("\nno hard import failures")
