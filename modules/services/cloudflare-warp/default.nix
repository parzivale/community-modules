{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.cloudflare-warp;

  # the daemon has no flag for its working directory, and nixos sets `WorkingDirectory`. So the
  # one thing a wrapper is needed for is the `cd`, and it is the only thing in here.
  warpSvc = pkgs.writeShellScript "warp-svc" ''
    cd ${cfg.rootDir}
    exec ${cfg.package}/bin/warp-svc
  '';
in
{
  options.services.cloudflare-warp = {
    enable = lib.mkEnableOption ''
      the Cloudflare Zero Trust client daemon.

      The package is unfree, so a machine enabling this needs `allowUnfree` for it - the
      failure is an evaluation error naming the package rather than anything about this module
    '';

    package = lib.mkPackageOption pkgs "cloudflare-warp" { };

    rootDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/cloudflare-warp";
      description = ''
        The working directory `warp-svc` is started in.

        Which is not the same as where it keeps its state, and the default being the same path
        hides that: `/var/lib/cloudflare-warp` is a string in the binary, so the registration
        and the account state go there whatever this says. Pointing this elsewhere moves where
        the daemon runs, not what it writes.
      '';
    };

    udpPort = lib.mkOption {
      type = lib.types.port;
      default = 2408;
      description = ''
        The UDP port to open in the firewall. Warp uses 2408 by default, and falls back to
        other pre-configured ports where that one is taken - see the
        [firewall documentation](https://developers.cloudflare.com/cloudflare-one/connections/connect-devices/warp/deployment/firewall#warp-udp-ports).
      '';
    };

    openFirewall = lib.mkEnableOption "opening the UDP port above in the firewall" // {
      default = true;
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    providers.firewall.allowedUDPPorts = lib.mkIf cfg.openFirewall [ cfg.udpPort ];

    # `StateDirectory`, `RuntimeDirectory` and `LogsDirectory` upstream, which are three
    # directories and one systemd feature. The contract has tmpfiles, so they are three rules.
    #
    # The state directory is named alongside `rootDir`, deduplicated because on the default they
    # are one path: the daemon writes to /var/lib/cloudflare-warp whatever its working directory
    # is, so the rule has to exist even where `rootDir` points somewhere else.
    providers.services.tmpfiles.rules =
      let
        directory = mode: path: {
          inherit path;
          type.directory = {
            inherit mode;
            user = "root";
            group = "root";
          };
        };
      in
      # 0755 on the runtime and log directories, which is what systemd's `RuntimeDirectory` and
      # `LogsDirectory` default to and not a detail: the daemon binds its IPC socket at
      # /run/cloudflare-warp/warp_service, and `warp-cli` run by a user has to traverse that
      # directory to reach it. 0700 here is a daemon nothing but root can talk to.
      #
      # 0700 on the state directory, which is the one divergence from upstream: it holds the
      # registration and the account state, and nothing reads them but the daemon.
      map (directory "0755") (
        lib.unique [
          "/run/cloudflare-warp"
          "/var/log/cloudflare-warp"
        ]
      )
      ++ map (directory "0700") (
        lib.unique [
          cfg.rootDir
          "/var/lib/cloudflare-warp"
        ]
      );

    providers.services.units.cloudflare-warp = {
      description = "Cloudflare Zero Trust client daemon";

      # `network.target` upstream, and `After=pre-network.target` in the unit Cloudflare ships.
      # Neither has a counterpart here; `network-online` is the trunk's, and is what the
      # tailscale module names for the same reason. Stricter than either - interfaces up rather
      # than merely configured - which for something whose whole job is a tunnel is the right
      # way round.
      #
      # And dbus where there is one. The daemon opens the system bus to ask about DNS -
      # `org.freedesktop.resolve1` and `org.freedesktop.systemd1` are both in the binary - and
      # on a finix machine neither name is on it, so it falls back to writing /etc/resolv.conf
      # itself. That fallback is the supported path here and it needs no bus, but a daemon which
      # starts before dbus and asks once has a different answer than one which asks after it.
      requires = [
        "network-online"
      ]
      ++ lib.optional config.services.dbus.enable "dbus";

      type.service = {
        command = "${warpSvc}";

        # the socket its clients use, which is better than what upstream can say about itself.
        # nixos has `Type=simple`, so systemd calls this up the instant the process exists -
        # which is some seconds before the daemon is usable: it synchronises time, reads its
        # settings, migrates its database and only then binds the socket, logging
        #
        #   warp_net::ipc::core: Bound ipc socket name="cloudflare-warp/warp_service"
        #                                         path="/run/cloudflare-warp/warp_service"
        #
        # `warp-cli` and `warp-taskbar` are clients of that socket, so "it answers" is the
        # condition they need, and `waitFor.socket` connects rather than stat-ing the path.
        #
        # No `notify`: the daemon does not speak sd_notify, which is why upstream is
        # `Type=simple` in the first place.
        readiness = [ { waitFor.socket.path = "/run/cloudflare-warp/warp_service"; } ];
      };

      # lsof, which the daemon runs to find out which UDP port is already taken when it has to
      # fall back.
      path = [ pkgs.lsof ];

      environment.RUST_BACKTRACE = "full";
    };

    # `CapabilityBoundingSet` and `AmbientCapabilities` have no counterpart, and the unit runs
    # as root either way - so what is lost is the bound, not a capability the daemon needs.
    # Worth knowing rather than silently dropped: upstream names three (CAP_NET_ADMIN,
    # CAP_NET_BIND_SERVICE, CAP_SYS_PTRACE) and Cloudflare's own unit names seven. The same goes
    # for `ReadWritePaths`, which was a sandbox over /etc/resolv.conf and the state directory.
  };
}
