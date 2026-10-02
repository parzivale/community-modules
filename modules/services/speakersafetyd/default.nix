{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.speakersafetyd;
in
{
  imports = [ ./providers.services.nix ];

  options.services.speakersafetyd = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [speakersafetyd](${pkgs.speakersafetyd.meta.homepage}), which
        implements the Smart Amp protection model.

        ::: {.warning}
        This is not a convenience. On hardware whose speakers are driven beyond what they can
        take without it - Apple Silicon machines are the case it exists for - running audio
        without this daemon can damage them physically. Enable it with the audio stack, not
        after.
        :::
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.speakersafetyd;
      defaultText = lib.literalExpression "pkgs.speakersafetyd";
      description = ''
        The package to use for `speakersafetyd`.
      '';
    };

    session = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      example = "alice";
      description = ''
        Run in this user's session tree rather than as a system service.

        The ordering is why. The daemon reads the card's sample rate while it initialises, and
        a sound server opening the device at the same moment changes it underneath:

            PCM rate: 8000..192000
            thread 'main' panicked at src/main.rs:298:17:
            Invalid sample rate

        which is a restart and a few seconds with the speakers at the kernel's own limit. It
        wants to start *after* the sound server, and that edge cannot be written any other
        way: a system unit cannot depend on a user unit, so the only place to say "after
        pipewire" is beside pipewire.

        What it does not give up is CAP_SYS_NICE, and that was the first answer here and the
        wrong one. The capability looks optional - `sched_setattr` failing is a `warn!`, not an
        exit - but `Speaker Volume Unlock` is written at the bottom of every loop iteration and
        the driver treats it as a watchdog. A loop scheduled late misses the deadline, the driver
        locks the speakers itself, and the next write fails because the window has closed. So the
        session's user has to be in the `speakersafetyd` group, which gates the wrapper that
        grants it. On a machine whose only human is already in `wheel` that grants nothing new;
        on a shared one it is a real decision, which is why this module will not make it.

        What it does give up is the flag file. /run/speakersafetyd is the system instance's and
        cannot be written from a session, and that fails in the safe direction: its absence means
        "warm boot", and warm boot is the conservative branch - the coils are assumed to be at
        the thermal limit and gain is held down until the model cools them, where a cold boot
        assumes they are cold and allows full output at once.

        What it does give up is scope. Protection then exists while a session does, which is
        sound on hardware whose driver keeps the speakers limited until this daemon unlocks
        them - no session is quiet speakers, not unprotected ones - and wrong on hardware
        where anything can drive them without one. Leave this null there.
      '';
    };

    maxReduction = lib.mkOption {
      type = with lib.types; nullOr number;
      default = 7;
      description = ''
        Gain reduction, in dB, past which the daemon gives up and exits rather than carrying
        on - `--max_reduction`. Exiting is the point: the supervisor restarts it, and a
        protection loop that has run out of headroom is one whose state should be rebuilt
        rather than trusted. 7 is what the unit the package ships uses.

        `null` leaves it unbounded.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        # The udev rules are the package's either way: they are what gives the control device
        # the ownership the daemon needs, whichever account ends up running it.
        services.udev.packages = [ cfg.package ];

        # The group and the wrapper are needed wherever this runs, which was not the first
        # answer here and is the important one.
        #
        # `AmbientCapabilities = CAP_SYS_NICE` in the shipped unit, and a wrapper is how that is
        # granted here - the same mechanism `gamemoded` uses for the same capability. It reads
        # like a nicety: the daemon asks for its loop to be scheduled promptly through
        # `sched_setattr`, and failing that is a `warn!` rather than an exit, so a run without it
        # starts and protects and looks fine.
        #
        # It is not a nicety. `Speaker Volume Unlock` is written at the bottom of every loop
        # iteration and the driver treats it as a watchdog - miss the deadline and it locks the
        # speakers itself:
        #
        #   snd-soc-macaudio sound: Speaker volumes locked: Lock timeout
        #
        # and the next heartbeat then fails, because the window has closed:
        #
        #   Could not write elem value Speaker Volume Unlock. alsa-lib error:
        #   ALSA function 'snd_ctl_elem_write' failed with error 'Connection timed out (110)'
        #
        # which is a panic, a restart, an unlock, and the same deadline missed again. Four times
        # in seven seconds on the machine this was found on, until the supervisor gave up and the
        # speakers stayed locked. Under load, a daemon without this capability does not run with
        # more jitter - it stops working.
        #
        # The group gates the wrapper, so this grants nothing by itself: an account has to be put
        # in it. A system instance has one of its own below; a session instance needs its user
        # added, which is the host's decision and documented on `session`.
        users.groups.speakersafetyd = { };

        security.wrappers.speakersafetyd = {
          source = lib.getExe cfg.package;
          capabilities = "cap_sys_nice+ep";
          owner = "root";
          group = "speakersafetyd";
          permissions = "u+rx,g+x";
        };
      }

      # The account and the runtime directory are the system service's alone. A session instance
      # runs as the session's user and cannot write to /run/speakersafetyd - see `session` for
      # why that is the safe direction rather than a loss.
      (lib.mkIf (cfg.session == null) {
        # `DynamicUser = true` in the unit the package ships, which systemd reads as "invent
        # this user for the lifetime of the service". There is nothing to read it here, so the
        # account is declared - and `audio` with it, which is the `SupplementaryGroups` line:
        # the daemon opens the ALSA control device to watch and attenuate.
        users.users.speakersafetyd = {
          isSystemUser = true;
          group = "speakersafetyd";
          extraGroups = [ "audio" ];
        };

        # `RuntimeDirectory = speakersafetyd`, which is where it keeps
        # /run/speakersafetyd/speakersafetyd.flag - the marker saying the speakers have been
        # handed over to it. Nothing else creates the directory here.
        providers.services.tmpfiles.rules = [
          {
            path = "/run/speakersafetyd";
            # `mode`, `user` and `group` belong to the kind rather than to the rule: what they
            # mean depends on what is being created.
            type.directory = {
              user = "speakersafetyd";
              group = "speakersafetyd";
              mode = "0755";
            };
          }
        ];
      })
    ]
  );
}
