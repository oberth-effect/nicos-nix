# End-to-end: run the demo instrument's services under systemd and drive the
# daemon over the network.
{
  self,
  pkgs,
  testers,
  ...
}:
let
  # A store file rather than an inlined heredoc: the test script is itself
  # Python and gets type-checked, so embedding a multi-line program in a string
  # literal does not survive.
  driveDaemon = pkgs.writeText "nicos-drive-daemon.py" ''
    from nicos.clients.base import NicosClient, ConnectionData

    events = []


    class C(NicosClient):
        def signal(self, name, data=None, exc=None):
            events.append((name, data, exc))


    c = C(lambda *a, **k: None)
    # connect() returns None on every path; success is reported through
    # signal() and c.isconnected.
    c.connect(ConnectionData("localhost", 1301, "guest", ""))
    assert c.isconnected, [e for e in events if e[0] in ("failed", "error", "broken")]
    assert c.eval("1+1", None) == 2
    print("daemon version:", c.daemon_info.get("daemon_version"))
    c.disconnect()
    print("CLIENT OK")
  '';
in
testers.runNixOSTest {
  name = "nicos-demo";

  nodes.server =
    { pkgs, ... }:
    {
      # The overlay-free module: runNixOSTest puts nixpkgs in read-only mode,
      # so a module setting nixpkgs.overlays would conflict. The nodes already
      # get our overlaid pkgs, because this file is instantiated from them.
      imports = [ self.nixosModules.nicos ];

      services.nicos = {
        enable = true;
        setupPackages = [ pkgs.nicosDemoRebased ];
        setupPackage = "nicos_demo";
        instrument = "demo";
        services = [
          "cache"
          "poller"
          "daemon"
        ];
        openFirewall = true;
      };

      # The stock demo setups write to paths relative to nicos_root; the
      # rebased package points them at /tmp/nicos-demo instead.
      systemd.tmpfiles.settings."99-demo"."/tmp/nicos-demo/data".d = {
        user = "nicos";
        group = "nicos";
        mode = "0770";
      };

      virtualisation = {
        memorySize = 2048;
        cores = 2;
        diskSize = 4096;
        # The default 9p msize of 16 KiB is a severe bottleneck for a store
        # this full of small files (a Python env is tens of thousands of them),
        # and NICOS's closure makes boot dominate the run time.
        msize = 262144;
      };
      documentation.enable = false;
      nix.enable = false;
    };

  testScript =
    { nodes, ... }:
    let
      nicos = nodes.server.services.nicos.finalPackage;
    in
    ''
      start_all()
      server.wait_for_unit("nicos.target")

      with subtest("every unit is up"):
          server.wait_for_unit("nicos-cache.service")
          server.wait_for_open_port(14869)
          server.wait_for_unit("nicos-daemon.service")
          server.wait_for_open_port(1301)
          server.wait_for_unit("nicos-poller.service")

      with subtest("the Type=notify contract actually holds"):
          # A unit that forked would be restarted or report MainPID 0;
          # asserting only is-active would not catch that.
          for unit in ["nicos-cache", "nicos-poller", "nicos-daemon"]:
              t = server.succeed(f"systemctl show -p Type --value {unit}.service").strip()
              assert t == "notify", f"{unit} Type={t}"
              pid = server.succeed(f"systemctl show -p MainPID --value {unit}.service").strip()
              assert pid != "0", f"{unit} has no main PID"
              n = server.succeed(f"systemctl show -p NRestarts --value {unit}.service").strip()
              if n != "0":
                  # Report *why* before failing: a restart here means either a
                  # real Type=notify violation or a start timeout.
                  print(server.succeed(
                      f"systemctl show {unit}.service "
                      "-p Result -p ExecMainStatus -p ExecMainCode -p NRestarts "
                      "-p TimeoutStartUSec"
                  ))
                  print(server.succeed(f"journalctl -u {unit}.service --no-pager | tail -40"))
                  raise AssertionError(
                      f"{unit} restarted {n} times -- see Result/journal above"
                  )

      with subtest("no stray units from nicos-late-generator"):
          # Generator output lands in /run/systemd/system, which outranks
          # /etc/systemd/system and would silently shadow ours.
          server.fail("test -e /run/systemd/system/nicos-cache.service")

      with subtest("ordering, grouping and the cache dependency rule"):
          server.succeed("systemctl show -p After --value nicos-daemon.service | grep -qw nicos-cache.service")
          server.succeed("systemctl show -p Requires --value nicos-daemon.service | grep -qw nicos-cache.service")
          server.fail("systemctl show -p Requires --value nicos-cache.service | grep -qw nicos-cache.service")
          server.succeed("systemctl show -p Slice --value nicos-daemon.service | grep -qx nicos.slice")

      with subtest("directories, ownership and logs"):
          assert server.succeed("stat -c %U /var/log/nicos").strip() == "nicos"
          assert server.succeed("stat -c %U:%a /var/lib/nicos").strip() == "nicos:2770"
          server.wait_until_succeeds("ls /var/log/nicos/cache/*.log")

      with subtest("nicos_root is the store root and the config resolves"):
          out = server.succeed(
              "${nicos}/bin/nicos-python -c "
              "'from nicos import config; print(config.nicos_root); "
              "print(config.setup_package); print(config.instrument)'"
          )
          root, pkg, instr = out.split()
          assert root.startswith("/nix/store/"), root
          assert pkg == "nicos_demo", pkg
          assert instr == "demo", instr

      with subtest("the daemon executes code for a real client"):
          print(server.succeed("${nicos}/bin/nicos-python ${driveDaemon}"))

      with subtest("the whole instrument restarts cleanly"):
          server.succeed("systemctl restart nicos.target")
          server.wait_for_unit("nicos-daemon.service")
          server.wait_for_open_port(1301)

      with subtest("stopping the target stops the services"):
          # Assert the mechanism statically, then wait for it: shutdown
          # propagation is asynchronous, and this VM is slow.
          server.succeed("systemctl show -p PartOf --value nicos-cache.service | grep -qw nicos.target")
          server.succeed("systemctl stop nicos.target")
          server.wait_until_fails("systemctl is-active nicos-cache.service", timeout=180)
    '';
}
