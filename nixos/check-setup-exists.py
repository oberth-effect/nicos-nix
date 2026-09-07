"""Assert that a NICOS special setup exists, for a mutable root.

Used as an ExecStartPre in services.nicos.root.mode = "mutable", where the
build-time check cannot run because the root does not exist at evaluation
time. Resolves the setup roots through NICOS itself rather than
reimplementing findSetupRoots.
"""

import os
import sys

from nicos import config

want = sys.argv[1]
roots = [
    os.path.join(config.setup_package_path, sd, "setups")
    for sd in config.setup_subdirs
]

if not any(
    os.path.isfile(os.path.join(r, "special", want + ".py"))
    or os.path.isfile(os.path.join(r, want + ".py"))
    for r in roots
):
    sys.exit(
        "nicos-nix: services requires the special setup %r, but no %r exists "
        "under any of %s. A service named '<proc>-<name>' loads "
        "setups/special/<proc>-<name>.py." % (want, want + ".py", roots)
    )

print("nicos-nix: ok, special setup %r exists" % want)
