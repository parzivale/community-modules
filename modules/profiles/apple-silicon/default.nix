# compatibility for nixos-apple-silicon, so that it can be evaluated by finix
#
# `nixos-apple-silicon` is a nixos module tree. It is not stamped with a class, so finix can
# import it - and then it writes to twenty-odd option paths, a dozen of which do not exist
# here. This declares those, and for each one either forwards the value somewhere that reads
# it, drops it with the reason written down, or refuses.
#
# Refusing matters. The temptation with a shim like this is to declare everything and ignore
# it, which turns "this option does not exist" into "this option does nothing" - and two of
# these carry speaker protection. A MacBook whose amps are driven without `speakersafetyd`
# and asahi's UCM limits can be damaged, so the audio path asserts rather than proceeding
# quietly. Everything needed to boot the machine works; sound is refused until it can be
# supervised properly.
{
  config,
  lib,
  pkgs,
  modules,
  ...
}:
let
  cfg = config.hardware.asahi;

  # A hwdb fragment reaches finix's hwdb.bin the same way any package's does - through
  # `services.udev.packages`, which the udev module already scans for `udev/hwdb.d/*`. So the
  # text becomes a package rather than needing a new mechanism.
  hwdbPackage = pkgs.writeTextDir "lib/udev/hwdb.d/90-apple-silicon.hwdb" config.services.udev.extraHwdb;
in
{
  # The two finix modules this writes into, named because it writes into them:
  # `programs.limine` takes the blob that boots the machine, and `services.rtkit` is where
  # nixos' `security.rtkit` lands. Importing them declares their options; each is still gated
  # on its own `enable`.
  imports = [
    modules.limine
    modules.rtkit
  ];

  options = {
    # The blob that boots the machine: m1n1, the device trees and U-Boot, concatenated.
    # nixos-apple-silicon writes it to all three loaders it knows, unconditionally, so all
    # three paths have to exist - but only one of them is read, and it is this one, finix's
    # limine module taking `programs.limine.additionalFiles`.
    boot.loader.limine.additionalFiles = lib.mkOption {
      type = with lib.types; attrsOf path;
      default = { };
      internal = true;
      description = ''
        Forwarded to {option}`programs.limine.additionalFiles`. Declared because
        `nixos-apple-silicon` writes nixpkgs' spelling of it.
      '';
    };

    # Not read. finix has no grub module, and no systemd-boot beyond the `enable` that
    # `nixos-compat` declares for tooling to look at - so the same blob arrives here twice
    # more and is dropped both times. It is the same value in all three, so nothing is lost.
    #
    # The whole of grub rather than its `extraFiles`, because nixos-apple-silicon assigns the
    # attribute set - efiSupport, efiInstallAsRemovable, device - in one go, and a shim that
    # named only the files it cared about would fail on `device`.
    boot.loader.grub = lib.mkOption {
      type = with lib.types; attrsOf anything;
      default = { };
      internal = true;
      description = "Accepted and ignored: finix has no grub. See `boot.loader.limine.additionalFiles`.";
    };

    boot.loader.systemd-boot.extraFiles = lib.mkOption {
      type = with lib.types; attrsOf path;
      default = { };
      internal = true;
      description = "Accepted and ignored: finix does not boot systemd-boot. See `boot.loader.limine.additionalFiles`.";
    };

    # `schedutil`, which the asahi kernel wants and which no `powerManagement` namespace
    # exists here to hold. Implemented below rather than dropped: the default governor on
    # these machines is a battery-life and thermal decision.
    powerManagement.cpuFreqGovernor = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      description = ''
        The CPU frequency governor to select at startup, written to every cpu's
        `scaling_governor`.
      '';
    };

    # nixos turns this into an ACL helper for realtime scheduling; finix has the same daemon
    # under `services.rtkit`, so this forwards to it.
    security.rtkit.enable = lib.mkEnableOption null // {
      description = "Forwarded to {option}`services.rtkit.enable`.";
    };

    services.udev.extraHwdb = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        hwdb entries, wrapped into a package and added to {option}`services.udev.packages` -
        which is how every other package's entries reach the database.
      '';
    };

    # Set to false, and false is already the case: there is no pulseaudio module here to turn
    # off. Declared so that saying so is not an error.
    services.pulseaudio.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      internal = true;
      description = "Accepted and ignored: finix has no pulseaudio module, so it is off regardless.";
    };

    # iio-sensor-proxy, which serves the ambient light sensor and the accelerometer. No finix
    # module, and it is not implemented here - what is lost is automatic brightness and screen
    # rotation, which is a missing convenience rather than a broken machine, so it warns.
    hardware.sensor.iio.enable = lib.mkEnableOption null // {
      description = "Accepted and warned about: finix has no iio-sensor-proxy module.";
    };

    # The sound block is `lib.mkIf (enable && setupAsahiSound)`, which does not spare these
    # from being declared: the module system matches definition paths against declarations
    # before it applies any condition, so an option written inside a disabled block still has
    # to exist. Hence declarations for options that are, with sound off, never read.
    #
    # Swallowing `systemd.services` and `systemd.user.services` is the one part of this file
    # to be uneasy about. Nothing on finix reads them, so any other nixos module setting a
    # unit now fails quietly here instead of loudly. It is scoped to what this file is for -
    # asahi puts ALSA_CONFIG_UCM2 on the pipewire and wireplumber units - and the assertion
    # below is what stops that turning into working-looking sound.
    services.pipewire = lib.mkOption {
      type = with lib.types; attrsOf anything;
      default = { };
      internal = true;
      description = ''
        Declared, not forwarded. finix spells it `programs.pipewire`, and the difference is
        not only the name: pipewire is a user service there and finix's module starts nothing,
        so forwarding would produce configuration with no daemon. See the assertions.
      '';
    };

    systemd.services = lib.mkOption {
      type = with lib.types; attrsOf anything;
      default = { };
      internal = true;
      description = "Accepted and ignored: finix has no systemd. See the assertions.";
    };

    systemd.user.services = lib.mkOption {
      type = with lib.types; attrsOf anything;
      default = { };
      internal = true;
      description = "Accepted and ignored: finix has no systemd user session. See the assertions.";
    };

    # Units shipped by a package, which is how `speakersafetyd` is meant to arrive. finix has
    # no systemd to read them, and this one is not optional on the hardware, so it is refused
    # rather than dropped - see the assertion below.
    systemd.packages = lib.mkOption {
      type = with lib.types; listOf package;
      default = [ ];
      description = "Refused rather than ignored where the units matter. See the assertions.";
    };

    # Only ever "put these in the installer image", which a deployed host has no use for.
    system.extraDependencies = lib.mkOption {
      type = with lib.types; listOf package;
      default = [ ];
      internal = true;
      description = "Accepted and ignored: an installer-image concern.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # The whole reason this file does not simply declare and forget. `speakersafetyd`
        # implements the Smart Amp protection model, and asahi's UCM configuration carries the
        # limits it enforces against; pipewire on finix is not supervised at all yet, its
        # module laying down configuration and starting nothing. Sound that comes up without
        # those is sound that can damage the speakers, so it is refused here rather than
        # discovered later.
        assertion = config.systemd.packages == [ ];
        message = ''
          nixos-apple-silicon wants units from ${
            lib.concatMapStringsSep ", " (p: p.pname or p.name) config.systemd.packages
          }, which finix cannot read.

          Where that is speakersafetyd - it is, on this hardware - do not work around this.
          It implements the Smart Amp protection model, and driving these speakers without it
          can damage them. Sound needs three things finix does not have yet: speakersafetyd as
          a providers.services unit, pipewire and wireplumber supervised as session services,
          and ALSA_CONFIG_UCM2 reaching both of them.

          Until then, leave sound off: `hardware.asahi.enable` with
          `hardware.asahi.setupAsahiSound = false`.
        '';
      }
    ];

    warnings = lib.optional config.hardware.sensor.iio.enable ''
      nixos-apple-silicon enables iio-sensor-proxy, which finix has no module for. Automatic
      brightness and screen rotation will not work; nothing else is affected.
    '';

    # The forwards.
    programs.limine.additionalFiles = config.boot.loader.limine.additionalFiles;

    services.rtkit.enable = lib.mkIf config.security.rtkit.enable true;

    services.udev.packages = lib.mkIf (config.services.udev.extraHwdb != "") [ hwdbPackage ];

    # `schedutil` and the rest are set once, early, for every cpu that has a governor to set.
    # A oneshot rather than a service: it writes and finishes.
    providers.services.units = lib.mkIf (config.powerManagement.cpuFreqGovernor != null) {
      cpufreq-governor = {
        description = "select the cpu frequency governor";

        requires = [ "sysinit" ];

        type.oneshot.command = toString (
          pkgs.writeShellScript "cpufreq-governor" ''
            set -eu

            for policy in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
              [ -w "$policy" ] || continue
              echo ${config.powerManagement.cpuFreqGovernor} > "$policy"
            done
          ''
        );
      };
    };
  };
}
