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
  # the arguments, which are the same wherever it runs
  args = [
    "--config-path"
    "${cfg.package}/share/speakersafetyd/"
  ]
  ++ lib.optionals (cfg.maxReduction != null) [
    "--max-reduction"
    (toString cfg.maxReduction)
  ];
in
{
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # the system service: its own account, the wrapper for CAP_SYS_NICE, and a tier early
      # enough that everything which makes sound is behind it
      (lib.mkIf (cfg.session == null) {
        providers.services.units.speakersafetyd = {
          description = "speaker protection daemon";

          # A level earlier makes the ordering structural rather than a named edge each audio
          # consumer has to remember. `multi-user` is not reached until this is started, so
          # everything attached to it - a display manager, a session, and therefore every user
          # tree - is after it.
          #
          # "Started" and not "ready", and the difference is a real window. A unit's readiness
          # defaults to `fork`, so finit asserts this one the instant the process exists, and
          # `basic` is satisfied while the daemon is still working out what it is protecting.
          # The session comes up underneath it. It cannot be closed from here either:
          # speakersafetyd has no readiness protocol - Type=simple, no sd_notify, and the one
          # file it creates is a cold-boot marker written seconds before anything can go wrong.
          #
          # What goes wrong is the sound server opening the card while this is reading its
          # sample rate, which is a panic and a restart. `session` is the way out of that, and
          # the reason it exists: beside the sound server, the edge can simply be written.
          #
          # The cost of this tier is that a machine which cannot protect its speakers does not
          # reach `multi-user`, so a failure here takes the graphical session with it rather
          # than leaving it silent. On hardware that needs this that is the right way round.
          requires = [
            "basic"
            "suid-sgid-wrappers"
          ];

          # The wrapper, not the binary, so the process gets CAP_SYS_NICE. See the capability
          # note beside it.
          type.service.command = lib.concatStringsSep " " ([ "${launcher}" ] ++ args);

          user = "speakersafetyd";
          group = "speakersafetyd";

          # `Restart = on-failure` with a one second delay and a burst limit, all of which a
          # supervisor restarting a dead service already is. It matters more here than usual:
          # the daemon exits on purpose when gain reduction passes `maxReduction`, so
          # restarting is part of how it works rather than only how it recovers.
        };
      })

      # the session service: the same wrapper, the same capability, and the one edge a system
      # unit could not express
      (lib.mkIf (cfg.session != null) {
        providers.services.users.${cfg.session}.units.speakersafetyd = {
          description = "speaker protection daemon";

          # The whole point. The sound server configures the card and this reads what it
          # configured; started first it reads a rate which changes underneath it and panics. A
          # system unit cannot name a user unit, so this edge exists only here.
          #
          # `pipewire` resolves to the readiness companion rather than the process, and
          # pipewire's readiness is a socket it has to answer on - so this starts when the sound
          # server is actually serving, not when it has been forked.
          requires = [ "pipewire" ];

          # The wrapper, not the binary, and that was learned the hard way: without CAP_SYS_NICE
          # the loop misses the driver's watchdog deadline under load, the speakers lock
          # themselves, and every restart does it again. See the note beside the wrapper.
          #
          # Named directly rather than through a launcher, unlike the system unit. finit checks a
          # command exists when it parses its configuration, which is before /run/wrappers is
          # populated; this supervisor is started by a session, long after.
          type.service.command = lib.concatStringsSep " " ([ "/run/wrappers/bin/speakersafetyd" ] ++ args);
        };
      })
    ]
  );
}
