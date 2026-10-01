# Pure helpers shared by the NixOS module and the flake's `lib` output.
# Depends on nothing but `lib`.
{ lib }:
rec {
  # Exactly the directories under nicos/services/ in the NICOS source, i.e.
  # the set of `bin/nicos-<proc>` binaries that are services.
  knownProcNames = [
    "cache"
    "collector"
    "daemon"
    "elog"
    "monitor"
    "poller"
    "watchdog"
  ];

  # NICOS service names are `<proc>` or `<proc>-<instance>`; the latter runs
  # `nicos-<proc> -S <proc>-<instance>`, i.e. it loads a differently named
  # special setup. "monitor-html" is the common case -- there is no
  # nicos-monitor-html binary.
  #
  # Upstream's etc/nicos-late-generator does `name.split('-')` and therefore
  # raises on more than one dash. We handle it, but warn.
  splitServiceName =
    name:
    let
      parts = lib.splitString "-" name;
    in
    {
      procName = lib.head parts;
      instance = if lib.length parts > 1 then lib.concatStringsSep "-" (lib.tail parts) else null;
      dashes = lib.length parts - 1;
    };

  # THE naming rule. `instance == null` is today's flat `services.nicos`, and
  # those unit names are permanent; a future services.nicos.instances.<name>
  # gains the prefix without renaming anything that exists now.
  unitNameFor =
    {
      instance ? null,
      service,
    }:
    if instance == null then "nicos-${service}" else "nicos-${instance}-${service}";

  targetNameFor =
    {
      instance ? null,
    }:
    if instance == null then "nicos" else "nicos-${instance}";

  # "LimitRSS=2G" -> { name = "LimitRSS"; value = "2G"; }
  # Splits on the first '=' only, so Environment=FOO=bar survives.
  propToAttr =
    p:
    let
      parts = lib.splitString "=" p;
    in
    lib.nameValuePair (lib.head parts) (lib.concatStringsSep "=" (lib.tail parts));

  propsToAttrs = ps: lib.listToAttrs (map propToAttr ps);

  # Informational only: the authoritative values live in the user's
  # setups/special/{cache,daemon}.py.
  defaultPorts = {
    cache = 14869;
    daemon = 1301;
  };
}
