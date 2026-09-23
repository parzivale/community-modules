{
  lib,
  pkgs,
  config,
  ...
}:

let
  cfg = config.services.soteria;
in
{
  options.services.soteria = {
    enable = lib.mkEnableOption null // {
      description = ''
        Whether to enable Soteria, a Polkit authentication agent
        for any desktop environment.

        ::: {.note}
        You should only enable this if you are on a Desktop Environment that
        does not provide a graphical polkit authentication agent, or you are on
        a standalone window manager or Wayland compositor.
        :::
      '';
    };
    package = lib.mkPackageOption pkgs "soteria" { };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    assertions = [
      {
        assertion = config.services.elogind.enable && config.services.polkit.enable;
        message = "`services.elogind.enable` and `services.polkit.enable must both be set to true for soteria to function.";
      }
    ];

    providers.services.units.polkit-soteria = {
      description = "Soteria, Polkit authentication agent for any desktop environment";

      # polkit directly, rather than a runlevel: the agent is useless without
      # it, and the trunk says nothing about polkit being up.
      requires = [ "polkit" ];

      type.service.command = lib.getExe cfg.package;
    };
  };
}
