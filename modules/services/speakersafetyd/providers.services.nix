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
  # `2>&1`, because everything this daemon has to say it says on stderr and finit's `log`
  # takes stdout. It exits 101 on a panic, which is a Rust assertion or unwrap, and the message
  # naming which one went to the console and nowhere else - so the only trace of a boot where
  # the speakers went unprotected was finit reporting an exit status:
  #
  #   Service speakersafetyd[2025] died (with exit status: 101), restarting (attempt: 1/10)
  #   Successfully restarted crashing service speakersafetyd.
  #
  # Three seconds, every boot, healed by the restart and invisible. The binary carries two
  # assertions that would explain it - `2 * speaker_count <= globals.channels` and a speaker
  # count mismatch, both about the card not presenting what the config expects - and the
  # `snd_ctl_elem_lock` contention the tier below is written against would say something else
  # again. Which of those it is decides where the fix belongs, and until this line existed
  # there was no way to find out from the machine itself.
  launcher = pkgs.writeShellScript "speakersafetyd-launch" ''
    exec /run/wrappers/bin/speakersafetyd "$@" 2>&1
  '';
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.speakersafetyd = {
      description = "speaker protection daemon";

      # `basic`, so the whole userspace above it waits.
      #
      # `WantedBy = multi-user.target` in the shipped unit, and that is what this was - which put
      # it in the same tier as greetd and so concurrent with it. Speaker protection that races
      # the thing which starts the audio stack is protection that sometimes loses: both want the
      # card's control elements in the same second, speakersafetyd locks the ones it protects
      # with `snd_ctl_elem_lock`, and whoever asks second fails.
      #
      # A level earlier makes the ordering structural rather than a named edge each audio consumer
      # has to remember. `multi-user` is not reached until this is started, so everything attached
      # to it - a display manager, a session, and therefore every user tree - is after it.
      #
      # "Started" and not "ready", and the difference is the whole remaining problem. A unit's
      # readiness defaults to `fork`, so finit asserts this one the instant the process exists,
      # and `basic` is satisfied while the daemon is still working out what it is protecting. The
      # session comes up underneath it. On this machine that window is about three seconds and
      # the first instance dies inside it every boot, so the tier narrows the race rather than
      # removing it.
      #
      # It cannot be closed from here, because speakersafetyd has no readiness protocol to wait
      # on: its shipped unit is `Type=simple`, the binary has no sd_notify, and the one file it
      # creates - /run/speakersafetyd/speakersafetyd.flag - is written on startup to tell a cold
      # boot from a warm one, so it appears seconds before the failure and removing it to make it
      # mean something would change which state the daemon starts the amps in. So the honest fix
      # is upstream of readiness: whatever precondition the daemon is actually missing at that
      # moment, named as a dependency. The launcher's `2>&1` above is what makes it possible to
      # find out which.
      #
      # The cost is that a machine which cannot protect its speakers does not reach `multi-user`,
      # so a failure here takes the graphical session with it rather than leaving it silent. On
      # hardware that needs this that is the right way round, and it is the same judgement the
      # module already makes by asserting rather than dropping the unit quietly.
      #
      # `suid-sgid-wrappers` as well as the tier: the launcher execs the wrapper, so the wrapper
      # has to be there by the time it runs. It attaches to no level of its own, so it is
      # available in any tier.
      requires = [
        "basic"
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
