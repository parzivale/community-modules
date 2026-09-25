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
  options,
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
  # The finix modules this writes into, named because it writes into them: `programs.limine`
  # takes the blob that boots the machine, `services.rtkit` is where nixos' `security.rtkit`
  # lands, and `powerManagement` holds the cpu governor. Importing them declares their options;
  # each is still gated on its own `enable`.
  imports = [
    modules.limine
    modules.rtkit

    # `powerManagement.cpuFreqGovernor`, which asahi sets to `schedutil` on these machines.
    # Declared by finix rather than here now, so this imports it instead of shadowing it.
    modules.power-management
    # A sibling in this repository rather than a finix module, so a path: `modules` is finix's
    # registry and does not carry what lives here.
    ../../services/speakersafetyd
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
        # Sound is no longer refused, so this is what replaced the refusal: a check that the
        # forward above has somewhere to land. Two pipewire modules exist for finix and only
        # one of them takes `configPackages` - community-modules'. Forwarding asahi-audio into
        # the other silently drops it, and what is dropped is the routing and the volume limits
        # `speakersafetyd` enforces against. That failure would be inaudible until it was not.
        assertion = config.services.pipewire == { } || options.programs.pipewire ? configPackages;
        message = ''
          nixos-apple-silicon's sound setup delivers asahi-audio through pipewire and
          wireplumber `configPackages`, and the pipewire module in this configuration has no
          such option - so it is finix's rather than community-modules'.

          asahi-audio carries the filters and the routing that speakersafetyd enforces against.
          Without it the daemon is protecting speakers that are being driven by the wrong
          profile, which is worse than either alone.

          Import `community-modules.nixosModules.pipewire` instead, and make sure something
          supervises pipewire and wireplumber - neither module starts them.
        '';
      }
      {
        # Anything else arriving in `systemd.packages` is a unit nobody has looked at, and this
        # file's whole argument is that a unit nobody has looked at should not be dropped
        # quietly. speakersafetyd is the one that has been.
        assertion = lib.all (p: (p.pname or p.name) == "speakersafetyd") config.systemd.packages;
        message = ''
          nixos-apple-silicon wants units from ${
            lib.concatMapStringsSep ", " (p: p.pname or p.name) (
              lib.filter (p: (p.pname or p.name) != "speakersafetyd") config.systemd.packages
            )
          }, which finix cannot read and which nothing here has translated.

          Look at what those units do before working around this. The reason this file refuses
          rather than ignoring is that one of these - speakersafetyd, now handled - is what
          keeps the speakers from being driven past what they can take.
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

    # `systemd.packages = [ speakersafetyd ]` is what asahi says; this is what it means. The
    # unit in that package cannot be read here, so the daemon has a finix module of its own and
    # this turns the one into the other - matched by name, so a future package arriving in that
    # list is noticed by the assertion rather than silently dropped.
    services.speakersafetyd.enable = lib.mkIf (lib.any (
      p: (p.pname or p.name) == "speakersafetyd"
    ) config.systemd.packages) true;

    # asahi-audio, which is the other half of the speaker protection: the filters and the
    # routing that `speakersafetyd` enforces against, delivered as pipewire and wireplumber
    # configuration. This is the forward that makes it arrive.
    #
    # `pulse.enable` is not forwarded and has nowhere to go: this module set has no such
    # option, pipewire-pulse being a process to run rather than a flag to set. Whoever
    # supervises pipewire supervises that too.
    #
    # Nor are the four `systemd.services`/`systemd.user.services` entries asahi uses to put
    # ALSA_CONFIG_UCM2 in the daemons' environment. It sets `environment.variables` as well,
    # which finix renders to /etc/profile.d/session-vars.sh - so a session that reads the
    # system environment gets the variable without any unit being named.
    programs.pipewire = {
      configPackages = config.services.pipewire.configPackages or [ ];
      wireplumber.configPackages = config.services.pipewire.wireplumber.configPackages or [ ];
    };
  };
}
