{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.cups;

  format = pkgs.formats.keyValue {
    listsAsDuplicateKeys = true;
    mkKeyValue = lib.generators.mkKeyValueDefault { } " ";
  };

  # chgrp USB devices that have a printer interface (class 07)
  chgrpPrinter = pkgs.writeShellScript "mdevd-chgrp-printer" ''
    for iface in /sys/$DEVPATH/*/bInterfaceClass; do
      [ -f "$iface" ] && read cls < "$iface" && [ "$cls" = "07" ] && chgrp ${cfg.group} /dev/$MDEV && exit 0
    done
  '';

  # Merge CUPS outputs + filters + drivers into one ServerBin tree
  bindir = pkgs.buildEnv {
    name = "cups-progs";
    paths = [
      cfg.package.out
      pkgs.libcupsfilters
      pkgs.cups-filters
      pkgs.ghostscript
    ]
    ++ cfg.drivers;
    pathsToLink = [
      "/lib"
      "/share/cups"
      "/bin"
    ];
    ignoreCollisions = true;
  };

  # Default cupsd.conf — only placed if /etc/cups/cupsd.conf doesn't exist
  # A string rather than `pkgs.writeText`: its one use is the tmpfiles rule below,
  # which wants the contents. Going through the store to read them back is
  # import-from-derivation - the file has to be built before the evaluation naming
  # it can finish, so a machine of another architecture cannot be evaluated without
  # a builder for it.
  defaultCupsdConf = ''
    LogLevel info
    Listen localhost:631
    Listen /run/cups/cups.sock
    WebInterface Yes
    DefaultAuthType Basic

    <Location />
      Order allow,deny
      Allow localhost
    </Location>
    <Location /admin>
      Order allow,deny
      Allow localhost
    </Location>
    <Location /admin/conf>
      AuthType Basic
      Require user @SYSTEM
      Order allow,deny
      Allow localhost
    </Location>
  '';
in
{
  options.services.cups = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.cups;
    };
    drivers = lib.mkOption {
      type = with lib.types; listOf package;
      default = [ ];
    };
    settings = lib.mkOption {
      type = lib.types.submodule {
        freeformType = format.type;
        options = {
          SystemGroup = lib.mkOption {
            type = with lib.types; listOf str;
            default = [
              "root"
              "wheel"
              "lpadmin"
            ];
            apply = lib.concatStringsSep " ";
            description = "Specifies the group(s) to use for @SYSTEM group authentication.";
          };

          ServerBin = lib.mkOption {
            type = lib.types.str;
            default = "${bindir}/lib/cups";
            description = "Specifies the directory containing the backends, CGI programs, filters, helper programs, notifiers, and port monitors.";
          };

          DataDir = lib.mkOption {
            type = lib.types.str;
            default = "${bindir}/share/cups";
            description = "Specifies the directory where data files can be found.";
          };

          DocumentRoot = lib.mkOption {
            type = lib.types.str;
            default = "${cfg.package.out}/share/doc/cups";
            description = "Specifies the root directory for the CUPS web interface content.";
          };

          SetEnv = lib.mkOption {
            type = with lib.types; attrsOf str;
            default = { };
            apply = lib.mapAttrsToList (k: v: "${k} ${v}");
            description = "Set the specified environment variable to be passed to child processes. Note: the standard CUPS filter and backend environment variables cannot be overridden using this directive.";
          };

          AccessLog = lib.mkOption {
            type = lib.types.str;
            default = "stderr";
            description = ''Defines the access log filename. Specifying a blank filename disables access log generation. The value "stderr" causes log entries to be sent to the standard error file when the scheduler is running in the foreground, or to the system log daemon when run in the background. The value "syslog" causes log entries to be sent to the system log daemon.'';
          };

          ErrorLog = lib.mkOption {
            type = lib.types.str;
            default = "stderr";
            description = ''Defines the error log filename. Specifying a blank filename disables error log generation. The value "stderr" causes log entries to be sent to the standard error file when the scheduler is running in the foreground, or to the system log daemon when run in the background. The value "syslog" causes log entries to be sent to the system log daemon.'';
          };

          PageLog = lib.mkOption {
            type = lib.types.str;
            default = "stderr";
            description = ''Defines the page log filename. The value "stderr" causes log entries to be sent to the standard error file when the scheduler is running in the foreground, or to the system log daemon when run in the background. The value "syslog" causes log entries to be sent to the system log daemon. Specifying a blank filename disables page log generation.'';
          };
        };
      };
      default = { };
      description = "Settings for cups-files.conf. See cups-files.conf(5).";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "cups";
      description = ''
        User account under which `cups` executes external programs.

        ::: {.note}
        If left as the default value this user will automatically be created
        on system activation, otherwise you are responsible for
        ensuring the user exists before the `cups` service starts.
        :::
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "lp";
      description = ''
        Group account under which `cups` executes external programs.

        ::: {.note}
        If left as the default value this group will automatically be created
        on system activation, otherwise you are responsible for
        ensuring the group exists before the `cups` service starts.
        :::
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.cups.settings = {
      SetEnv.PATH = "${bindir}/lib/cups/filter:${bindir}/bin";

      User = lib.mkForce cfg.user;
      Group = lib.mkForce cfg.group;
    };

    # boot.blacklistedKernelModules = [ "usblp" ];
    environment.etc."modprobe.d/usblp.conf".text = ''
      blacklist usblp
    '';

    services.mdevd.hotplugRules = lib.mkIf (config.services.mdevd.enable) (
      lib.mkBefore ''
        -SUBSYSTEM=usb;DEVTYPE=usb_device;.* root:root 0660 @${chgrpPrinter}
      ''
    );

    services.udev.packages = lib.mkIf (config.services.udev.enable) cfg.drivers;

    environment.systemPackages = [ cfg.package.out ];

    providers.services.units.cups = {
      description = "CUPS printing daemon";

      # was `service/syslogd/ready`: syslogd is in the head tier, so reaching
      # the multi-user tier is already after it.
      requires = [ "basic" ];

      type.service.command = "${cfg.package.out}/sbin/cupsd -f -c /etc/cups/cupsd.conf -s ${format.generate "cups-files.conf" cfg.settings}";
    };

    providers.services.tmpfiles.rules =
      map
        (dir: {
          path = dir.path;
          type.directory = {
            inherit (dir) mode;
            user = "root";
            inherit (cfg) group;
          };
        })
        [
          {
            path = "/etc/cups";
            mode = "0755";
          }
          {
            path = "/run/cups";
            mode = "0755";
          }
          {
            path = "/var/cache/cups";
            mode = "0700";
          }
          {
            path = "/var/lib/cups";
            mode = "0755";
          }
          {
            path = "/var/spool/cups";
            mode = "0700";
          }
          {
            path = "/var/spool/cups/tmp";
            mode = "0700";
          }
        ]
      ++ [
        # The old `C` rule copied the default config in only if none was there.
        # The contract has no copy kind, so name the contents instead: `file`
        # creates the path if it is absent and leaves an existing one alone,
        # which is the behaviour that rule was after.
        {
          path = "/etc/cups/cupsd.conf";
          type.file.argument = defaultCupsdConf;
        }
        {
          path = "/etc/cups/snmp.conf";
          type.file.argument = "Address @LOCAL";
        }
        {
          path = "/etc/cups/client.conf";
          type.file.argument = null;
        }
      ];

    users.users = lib.optionalAttrs (cfg.user == "cups") {
      cups = {
        inherit (cfg) group;

        description = "CUPS printing services";
      };
    };

    users.groups.lpadmin = { };
    users.groups.lp = lib.mkIf (cfg.group == "lp") { };
  };
}
