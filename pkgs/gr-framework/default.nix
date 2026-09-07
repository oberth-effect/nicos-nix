# The GR framework: the plotting runtime behind NICOS's Qt GUI.
#
# Not in nixpkgs. Debian ships it with a five-line debian/rules and no exotic
# patches, and the CMake path never touches the network:
# GR_USE_BUNDLED_LIBRARIES defaults to OFF, and the downloading 3rdparty/
# Makefiles are only reached via `make self`, which we never invoke.
{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  pkg-config,
  # required by CMake
  zlib,
  libpng,
  libjpeg,
  qhull,
  # optional; each missing one degrades its plugin to a stub
  freetype,
  bzip2,
  cairo,
  pixman,
  libtiff,
  ffmpeg,
  glfw,
  zeromq,
  ghostscript,
  xercesc,
  fontconfig,
  libGL,
  libGLU,
  libx11,
  libxt,
  libxft,
  libxext,
  # Qt: must be the SAME qtbase as the PyQt binding NICOS uses, because libGKS
  # dlopens qt6plugin.so and hands it a raw QWidget* unwrapped from PyQt via
  # sip. A mismatch segfaults rather than erroring cleanly.
  qtbase,
  qtsvg,
  wrapQtAppsHook,
  withQt ? true,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "gr-framework";
  version = "0.73.27";

  src = fetchFromGitHub {
    owner = "sciapp";
    repo = "gr";
    tag = "v${finalAttrs.version}";
    hash = "sha256-NOHDOIz5UfSjmpNn9hGDQWI6KlJ/g3r2x3yAHrO5m8k=";
  };

  postPatch = ''
    # cmake/GetVersionFromGit.cmake tries `git describe`, then version.txt,
    # then WARNS and sets 0.0.0. A fetchFromGitHub tarball has no .git and the
    # repo has no version.txt, so without this the build *succeeds* and then
    # python3Packages.gr silently rejects libGR for being older than the
    # required 0.71.5 -- surfacing only as "Failed to load GR runtime!".
    echo "${finalAttrs.version}" > version.txt
  '';

  strictDeps = true;
  nativeBuildInputs = [
    cmake
    pkg-config
  ]
  # GR installs Qt helper binaries alongside the libraries -- gksqt (which
  # libGKS launches for workstation types 411-413) and grplot. NICOS itself
  # uses the in-process Qt plugin (wstype 381) and never launches them, but
  # they should still get a working Qt environment.
  ++ lib.optional withQt wrapQtAppsHook;

  buildInputs = [
    zlib
    libpng
    libjpeg
    qhull
    freetype
    bzip2
    cairo
    pixman
    libtiff
    ffmpeg
    glfw
    zeromq
    ghostscript
    xercesc
    fontconfig
    libGL
    libGLU
    libx11
    libxt
    libxft
    libxext
  ]
  ++ lib.optionals withQt [
    qtbase
    qtsvg
  ];

  cmakeFlags = [
    # GR_DIRECTORY defaults to CMAKE_INSTALL_PREFIX and is baked in as -DGRDIR=,
    # so fonts ($out/fonts), plugins ($out/lib/*plugin.so) and gksqt all resolve
    # at runtime with no environment variables at all.
    (lib.cmakeFeature "GR_DIRECTORY" (placeholder "out"))
    (lib.cmakeBool "GR_USE_BUNDLED_LIBRARIES" false)
    (lib.cmakeBool "GR_BUILD_DEMOS" false)
    (lib.cmakeBool "GR_INSTALL" true)
  ];

  # `agg` is deliberately absent: it is GPL-2.0+, its plugin is optional, and
  # it is the only dependency needing a CMAKE_PREFIX_PATH hack.

  postInstall = ''
    # Nothing links the static variants.
    rm -f $out/lib/*.a
  '';

  # Upstream sets INSTALL_RPATH "${GR_DIRECTORY}/lib/;$ORIGIN/." which is
  # exactly what Nix wants -- do NOT strip it (Debian does, because it splits
  # the prefix across /usr/{bin,lib,share}; we install into one prefix).

  meta = {
    description = "Framework for cross-platform visualisation applications";
    homepage = "https://gr-framework.org/";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
})
