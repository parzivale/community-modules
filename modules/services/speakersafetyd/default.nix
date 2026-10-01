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

        What it gives up is a system service's privileges, and they turn out not to be needed.
        `CAP_SYS_NICE` is wanted rather than required - `sched_setattr` failing is a `warn!`,
        so the protection loop runs with more jitter and no less protection. The ALSA control
        device is reached through the session's own device ACLs, which is how the sound server
        reaches it. And the flag file at /run/speakersafetyd, which cannot be written from a
        session, fails in the safe direction: its absence means "warm boot", and warm boot is
        the conservative branch - the coils are assumed to be at the thermal limit and gain is
        held down until the model cools them, where a cold boot assumes they are cold and
        allows full output at once.

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
      }

      # Everything below is the system service's, and a session's instance needs none of it.
      # The account, because the session already has one. The wrapper, because the capability
      # it grants is optional and the group gating it is this account's. The runtime directory,
      # because a session cannot write there and is better off not - see `session`.
      (lib.mkIf (cfg.session == null) {
        # `DynamicUser = true` in the unit the package ships, which systemd reads as "invent
        # this user for the lifetime of the service". There is nothing to read it here, so the
        # account is declared - and `audio` with it, which is the `SupplementaryGroups` line:
        # the daemon opens the ALSA control device to watch and attenuate.
        users.groups.speakersafetyd = { };
        users.users.speakersafetyd = {
          isSystemUser = true;
          group = "speakersafetyd";
          extraGroups = [ "audio" ];
        };

        # `AmbientCapabilities = CAP_SYS_NICE` over there, and a wrapper is how that is granted
        # here - the same mechanism `gamemoded` uses for the same capability.
        #
        # It is wanted rather than needed. The daemon asks for utilization clamping through
        # `sched_setattr` so its loop keeps running promptly under load, and failing that is a
        # `warn!` rather than an exit - so without the capability it still protects, with more
        # scheduling jitter than it would like. The group is what gates the wrapper, so only
        # this daemon's account can use it.
        security.wrappers.speakersafetyd = {
          source = lib.getExe cfg.package;
          capabilities = "cap_sys_nice+ep";
          owner = "root";
          group = "speakersafetyd";
          permissions = "u+rx,g+x";
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
