# The GUI's import path, without needing a display.
#
# This is the regression test for the packaging-specific parts of the Qt story:
# the QtDesigner stub, the find_library fix behind the libGL preload, and GR's
# runtime discovery. All of those fail at *import* time, so no window is
# required to catch them.
#
# Not covered: the qtWrapperArgs splice (platform plugins, QML paths). It only
# goes into the bin/nicos-gui wrapper, and this runs nicos-python, which
# carries NICOS_LIBRARY_PATH but not the Qt environment.
{
  runCommand,
  nicosLib,
  nicosSetupPackages,
}:
let
  gui = nicosLib.mkNicos {
    pname = "nicos-gui-check";
    setupPackages = [ nicosSetupPackages.demo ];
    extras = [ "gui" ];
    settings = {
      setup_package = "nicos_demo";
      instrument = "demo";
      pid_path = "/tmp/nicos-demo/pid";
      logging_path = "/tmp/nicos-demo/log";
    };
  };
in
runCommand "nicos-gui-offscreen" { } ''
  export HOME="$TMPDIR"
  export XDG_RUNTIME_DIR="$TMPDIR"
  export QT_QPA_PLATFORM=offscreen

  ${gui}/bin/nicos-python - <<'PY'
  import gr
  import qtgr

  import nicos.guisupport.qt as q

  print("Qt version      :", q.QT_VERSION_STR)
  print("GR runtime      :", gr.__version__ if hasattr(gr, "__version__") else "loaded")

  # The QtDesigner stub: nixpkgs' pyqt6 has no such module, and
  # nicos/guisupport/qt.py imports it unconditionally.
  import PyQt6.QtDesigner as designer
  print("QtDesigner stub :", getattr(designer, "__nicos_nix_stub__", False))

  # These degrade to None upstream when unavailable; here they must be real,
  # because the whole point of targeting Qt6 was to keep them.
  assert q.QWebEngineView is not None, "QWebEngineView missing (the elog panel needs it)"
  assert q.QsciScintilla is not None, "QsciScintilla missing (the script editor needs it)"
  print("QWebEngineView  :", q.QWebEngineView.__name__)
  print("QsciScintilla   :", q.QsciScintilla.__name__)

  # The hard gr import, and the GUI entry point.
  import nicos.guisupport.plots
  import nicos.clients.gui.main
  import nicos.clients.gui.panels.elog
  import nicos.clients.gui.panels.editor

  print("GUI IMPORTS OK")
  PY
  touch $out
''
