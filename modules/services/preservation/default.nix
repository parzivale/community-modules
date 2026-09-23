{
  config,
  pkgs,
  lib,
  utils,
  ...
}:
let
  cfg = config.preservation;

  inherit (import ./lib.nix { inherit lib; })
    mkMountCmds
    ;

  inherit (utils) escapePath;

  mkCmds = prefix: lib.flatten (lib.mapAttrsToList (mkMountCmds prefix) cfg.preserveAt);

  mkScript =
    name: prefix:
    pkgs.writeScript name ''
      #!/bin/sh
      ${lib.concatStringsSep "\n" (mkCmds prefix)}
    '';

  mountConditions = lib.concatMapStringsSep "," (root: "task/mount-${escapePath root}/success") (
    lib.attrNames cfg.preserveAt
  );
in
{
  imports = [
    ./options.nix
  ];

  # Where the work happens depends on whether there is an initrd to do it in.
  #
  # With one, it belongs there: bind mounts made before switch_root survive it, so every
  # preserved path is in place from the very first moment of stage 2 - including the ones
  # stage 2 itself reads, like /etc/machine-id.
  #
  # Without one, there is no earlier place to stand. The same commands run against the
  # already-mounted root as a unit at the head of the trunk: after `mount-filesystems`,
  # because the preserved root has to be mounted first, and named on `start` so the `sysinit`
  # anchor waits for it and everything attached to any later level is behind it.
  config = lib.mkIf (cfg.enable && mkCmds "" != [ ]) (
    lib.mkMerge [
      (lib.mkIf config.boot.initrd.enable {
        boot.initrd.contents = [
          {
            target = "/usr/local/bin/preservation";
            source = mkScript "preservation-initrd" "/sysroot";
          }
          {
            target = "/etc/finit.d/preservation.conf";
            source = pkgs.writeText "preservation-finit-initrd.conf" ''
              run [S] name:preservation <${mountConditions}> preservation
            '';
          }
        ];
      })

      (lib.mkIf (!config.boot.initrd.enable) {
        providers.services.units.preservation = {
          description = "mount preserved state";

          requires = [
            "start"
            "mount-filesystems"
          ];

          type.oneshot.command = mkScript "preservation" "";
        };
      })
    ]
  );
}
