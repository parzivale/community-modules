# how services.speakersafetyd runs, as providers.services units
#
# Separated from the module's own options and configuration so that what this module asks of
# the service contract is in one place, the same way a module implementing a `providers.*`
# contract keeps its implementation in a file named for it.
{
  config,
  lib,
  ...
}:
let
  cfg = config.services.speakersafetyd;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.speakersafetyd = {
      description = "speaker protection daemon";

      # `WantedBy = multi-user.target` in the shipped unit. Nothing requires this in turn,
      # which is worth being clear-eyed about: the audio stack does not wait for it, so a
      # machine can be making sound before protection is up. The window is a startup one and
      # the daemon is the thing that closes it.
      requires = [ "multi-user" ];

      # The wrapper, not the binary, so the process gets CAP_SYS_NICE. See the capability note
      # beside it.
      type.service.command = lib.concatStringsSep " " (
        [
          "/run/wrappers/bin/speakersafetyd"
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
