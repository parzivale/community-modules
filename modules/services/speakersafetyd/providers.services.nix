# how services.speakersafetyd runs, as providers.services units
#
# Separated from the module's own options and configuration so that what this module asks of
# the service contract is in one place, the same way a module implementing a `providers.*`
# contract keeps its implementation in a file named for it.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.speakersafetyd;

  # The wrapper is what has to run - see the capability note beside its declaration - but it
  # cannot be what the unit names. finit checks a unit's command exists when it reads the
  # configuration, which is before anything has populated /run/wrappers, so a unit pointing
  # straight at /run/wrappers/bin/speakersafetyd is not deferred, it is dropped:
  #
  #   service_register(): /etc/finit.d/speakersafetyd.conf: skipping
  #   /run/wrappers/bin/speakersafetyd: No such file or directory
  #
  # which is silent, permanent for that boot, and leaves the speakers unprotected. Requiring
  # `suid-sgid-wrappers` does not help; ordering is not the problem, existing at parse time is.
  #
  # So the unit names a store path which does exist then, and that execs the wrapper once the
  # boot has got far enough to have made one.
  launcher = pkgs.writeShellScript "speakersafetyd-launch" ''
    exec /run/wrappers/bin/speakersafetyd ""
  '';
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.speakersafetyd = {
      description = "speaker protection daemon";

      # `WantedBy = multi-user.target` in the shipped unit. Nothing requires this in turn,
      # which is worth being clear-eyed about: the audio stack does not wait for it, so a
      # machine can be making sound before protection is up. The window is a startup one and
      # the daemon is the thing that closes it.
      # `suid-sgid-wrappers` as well as the tier: the launcher execs the wrapper, so the wrapper
      # has to be there by the time it runs.
      requires = [
        "multi-user"
        "suid-sgid-wrappers"
      ];

      # The wrapper, not the binary, so the process gets CAP_SYS_NICE. See the capability note
      # beside it.
      type.service.command = lib.concatStringsSep " " (
        [
          "${launcher}"
          "--config-path"
          "${cfg.package}/share/speakersafetyd/"
        ]
        ++ lib.optionals (cfg.maxReduction != null) [
          "--max-reduction"
          (toString cfg.maxReduction)
        ]
      );

      user = "speakersafetyd";
      group = "speakersafetyd";

      # `Restart = on-failure` with a one second delay and a burst limit, all of which a
      # supervisor restarting a dead service already is. It matters more here than usual: the
      # daemon exits on purpose when gain reduction passes `maxReduction`, so restarting is
      # part of how it works rather than only how it recovers.
    };
  };
}
