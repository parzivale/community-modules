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

  config = lib.mkIf cfg.enable {
    # `DynamicUser = true` in the unit the package ships, which systemd reads as "invent this
    # user for the lifetime of the service". There is nothing to read it here, so the account
    # is declared - and `audio` with it, which is the `SupplementaryGroups` line: the daemon
    # opens the ALSA control device to watch and attenuate.
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
    # scheduling jitter than it would like. The group is what gates the wrapper, so only this
    # daemon's account can use it.
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
        # `mode`, `user` and `group` belong to the kind rather than to the rule: what they mean
        # depends on what is being created.
        type.directory = {
          user = "speakersafetyd";
          group = "speakersafetyd";
          mode = "0755";
        };
      }
    ];

    services.udev.packages = [ cfg.package ];
  };
}
