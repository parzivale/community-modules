{
  config,
  pkgs,
  lib,
  modules,
  ...
}:

let
  cfg = config.home-manager;
  hmPath = pkgs.home-manager.src;

  extendedLib = import "${hmPath}/modules/lib/stdlib-extended.nix" lib;

  hmModules = import "${hmPath}/modules/modules.nix" {
    lib = extendedLib;
    inherit pkgs;
    check = true;
  };

  userType = lib.types.submoduleWith {
    modules = hmModules ++ [
      # The generation is already pinned by the system closure, so a
      # separate GC root during activation is unnecessary and requires
      # ~/.local/state/home-manager/gcroots/ to pre-exist.
      { home.activationGenerateGcRoot = lib.mkDefault false; }
      # When enableProfileInstall is false (e.g. in VMs where /nix/store is a
      # read-only bind mount) skip the `nix profile install` step entirely.
      # Packages remain accessible via users.users.<name>.packages.
      (
        { lib, osConfig, ... }:
        lib.mkIf (!osConfig.home-manager.enableProfileInstall) {
          home.activation.installPackages = lib.mkForce (lib.hm.dag.entryAfter [ "writeBoundary" ] "");
        }
      )
      # Who the user is and where their home is are facts the system already
      # holds, so read them from there rather than making every configuration
      # repeat them. Defaults, so a user whose home is somewhere else says so.
      (
        {
          lib,
          osConfig,
          name,
          ...
        }:
        {
          home.username = lib.mkDefault name;
          home.homeDirectory = lib.mkDefault (osConfig.users.users.${name}.home or "/home/${name}");
        }
      )
    ];
    specialArgs = {
      inherit pkgs;
      lib = extendedLib;
      osConfig = config;
    };
  };
in
{
  imports = [ modules.nix-daemon ];

  options.home-manager = {
    enableProfileInstall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to run `nix profile install` during home-manager activation to
        register packages with the user's nix profile.

        Set to `false` when `/nix/store` is read-only (e.g. in QEMU VMs that
        bind-mount the host store). Packages remain accessible via the system
        closure regardless.
      '';
    };

    users = lib.mkOption {
      type = lib.types.attrsOf userType;
      default = { };
      description = ''
        Per-user home-manager configurations.

        ::: {.note}
        home-manager user services are not supported on finix as there is no
        systemd user session. Only `home.packages`, `home.file`, and
        program configuration options are usable.
        :::
      '';
    };
  };

  config = lib.mkIf (cfg.users != { }) {
    services.nix-daemon.enable = lib.mkDefault true;
    warnings = lib.concatLists (
      lib.mapAttrsToList (user: hmCfg: map (w: "[home-manager/${user}] ${w}") hmCfg.warnings) cfg.users
    );

    assertions = lib.concatLists (
      lib.mapAttrsToList (
        user: hmCfg: map (a: a // { message = "[home-manager/${user}] ${a.message}"; }) hmCfg.assertions
      ) cfg.users
    );

    users.users = lib.mapAttrs (user: hmCfg: {
      packages = [ hmCfg.home.path ];
    }) cfg.users;

    environment.pathsToLink = [ "/etc/profile.d" ];

    # The profile directory activation needs, which it looks for and does not create:
    #
    #   Could not find suitable profile directory, tried
    #     /home/bella/.local/state/nix/profiles and /nix/var/nix/profiles/per-user/bella
    #
    # and exits 1 on not finding one. On NixOS nix's own tmpfiles rules make it; there is no
    # equivalent here, so activation failed on every boot of every machine using this module -
    # immediately, and quietly. The task is simply `done (status=1)`, its readiness companion
    # waits for a success which is not coming, and nothing says that every file home-manager
    # would have linked is absent. What that looks like from the outside is the programs it
    # configures behaving as though they have no configuration: a compositor starting with
    # default settings, a themed cursor that is not themed.
    #
    # The whole chain is declared rather than just the leaf, because tmpfiles creates missing
    # parents as root - which would leave a root-owned ~/.local in someone's home directory.
    providers.services.tmpfiles.rules = lib.concatLists (
      lib.mapAttrsToList (
        user: _:
        let
          userCfg = config.users.users.${user};
        in
        map
          (path: {
            path = "${userCfg.home}/${path}";
            type.directory = {
              mode = "0755";
              inherit user;
              inherit (userCfg) group;
            };
          })
          [
            ".local"
            ".local/state"
            ".local/state/nix"
            ".local/state/nix/profiles"
          ]
      ) cfg.users
    );

    providers.services.units = lib.mapAttrs' (
      user: hmCfg:
      let
        userCfg = config.users.users.${user};
      in
      lib.nameValuePair "hm-activate-${user}" {
        description = "home-manager activation for ${user}";

        # was `service/syslogd/ready` + `service/nix-daemon/ready`. syslogd is in
        # the head tier; the daemon is named directly because activation builds
        # through it.
        #
        # `tmpfiles-setup` for the profile directory above. Both are in the sysinit region and a
        # tier starts together, so attaching to the level alone leaves this racing the unit which
        # creates the directory it needs - the same race dbus lost against /run/dbus.
        requires = [
          "nix-daemon"
          "tmpfiles-setup"
        ];

        type.oneshot.command = "${hmCfg.home.activationPackage}/activate";

        inherit user;

        path = [
          pkgs.nix
          pkgs.coreutils
          pkgs.bash
        ];

        environment = {
          HOME = userCfg.home;
          USER = user;
        };
      }
    ) cfg.users;
  };
}
