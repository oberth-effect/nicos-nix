# Phase 1 gate: every module in the NICOS core tree either imports, or fails
# only because an optional dependency is absent.
{
  runCommand,
  nicos,
}:
runCommand "nicos-import-sweep" { } ''
  export HOME="$TMPDIR"
  ${nicos}/bin/nicos-python ${./import_sweep.py} ${nicos.passthru.root}
  touch $out
''
