# Replaced by nicos-nix: the NICOS version is fixed at build time.
#
# Upstream runs `git describe` with cwd=config.nicos_root *before* falling back
# to nicos/RELEASE-VERSION. A /nix/store root has neither a .git directory nor
# git on PATH, so every `import nicos` paid a failed fork+exec -- and NICOS
# forks a lot (poller children, simulation subprocesses, watchdog scripts).
#
# Two upstream behaviours are deliberately preserved:
#
#  * the module-level config.apply() below. nicos/__init__.py imports this
#    module, so this call is what loads nicos.conf for every NICOS process.
#    Dropping it would silently change when configuration is applied.
#
#  * get_git_version(cwd=...) still really shells out to git. nicos.get_custom_version()
#    uses it against config.setup_package_path to report the *setup package's*
#    version, and that may well be a live checkout with real git metadata.

from os import path
from subprocess import PIPE, Popen

from nicos import config

__all__ = ['get_git_version', 'get_nicos_version']

config.apply()

_VERSION = '@version@'


def get_releasefile_path():
    # due to the way we import it, the path will point to the nicos dir.
    thispath = path.normpath(path.dirname(path.dirname(__file__)))
    return path.join(thispath, 'RELEASE-VERSION')


def translate_version(ver):
    ver = ver.lstrip('v').rsplit('-', 2)
    return '%s.post%s+%s' % tuple(ver) if len(ver) == 3 else ver[0]


def get_git_version(abbrev=4, cwd=None):
    if cwd is None:
        return _VERSION
    try:
        with Popen(['git', 'describe', '--abbrev=%d' % abbrev], cwd=cwd,
                   stdout=PIPE, stderr=PIPE) as p:
            stdout, stderr = p.communicate()
    except Exception as err:
        raise RuntimeError(str(err)) from None
    ver = translate_version(stdout.strip().decode('utf-8', 'ignore'))
    if ver:
        return ver
    raise RuntimeError(stderr.strip().decode('utf-8', 'ignore'))


def read_release_version():
    return _VERSION


def write_release_version(version):
    pass


def get_nicos_version(abbrev=4):
    return _VERSION


if __name__ == '__main__':
    print(get_nicos_version())
