{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.preservation;

  inherit (import ./lib.nix { inherit lib; })
    mkMountCmds
    getAllDirectories
    getAllFiles
    ;

  # ownership is applied from the initrd, where no passwd/group database exists
  # beyond root, so ids are resolved to numbers at evaluation time where they
  # are known. a statically assigned id is the only kind that can be known here:
  # anything userborn allocates during stage 2 activation does not exist yet.
  #
  # an unknown id falls back to the name, which `chown` in the initrd will not
  # be able to resolve. that entry then fails its guard and degrades to a
  # console warning like any other broken entry, rather than being refused at
  # build time - configuring ids is the caller's business.
  #
  # TODO: drop the name fallback and go back to static lookups only. it trades a
  # build-time error that named the option to set for a runtime failure that the
  # caller has to go read the console to find, which is a worse place to learn
  # about it. the fallback is only worth keeping until ownership can be applied
  # from stage 2, after userborn has allocated ids - at which point dynamic ids
  # work properly and none of this is needed.
  # how the script names its interpreter and its commands, which is not the same answer in both
  # places it runs.
  #
  # Named bare, they resolve against a PATH. A stage 2 unit has no PATH worth the name - a finit
  # unit's environment is exactly what its own unit file says - so there they are store paths,
  # which is what the no-initrd path needs and what it was given.
  #
  # The initrd cannot use store paths, and this is the part that reading the script does not
  # show. `boot.initrd.contents` is assembled by `makeInitrdNG`, whose dependency resolution is
  # ELF-only: `if let Ok(Object::Elf(e)) = Object::parse(&contents)` in make-initrd-ng's
  # `copy_file`, which then follows the interpreter, NEEDED libraries, runpaths and dlopen
  # notes. A shell script is not ELF, so it is copied verbatim and every store path in it -
  # the `#!` line included - is inert text pointing outside the image. The exec fails before
  # the first line runs.
  #
  # So the initrd gets bare names and /bin/sh. That is not the hope it looks like: the image's
  # contents are declared, by `boot.initrd.path`, which carries busybox for the shell and these
  # applets, and `lib.hiPrio util-linux.mount` on top of it because busybox's `mount` does not
  # understand the `X-mount.mkdir` option used below. A guarantee, written down somewhere else.
  #
  # Passed into lib.nix rather than resolved there, for the same reason `ids` is: that file is
  # `{ lib, ... }` and has no pkgs to resolve them with.
  commandsFor =
    variant:
    if variant == "initrd" then
      {
        mkdir = "mkdir";
        chown = "chown";
        chmod = "chmod";
        touch = "touch";
        ln = "ln";
        mount = "mount";
      }
    else
      {
        mkdir = "${pkgs.coreutils}/bin/mkdir";
        chown = "${pkgs.coreutils}/bin/chown";
        chmod = "${pkgs.coreutils}/bin/chmod";
        touch = "${pkgs.coreutils}/bin/touch";
        ln = "${pkgs.coreutils}/bin/ln";
        mount = "${pkgs.util-linux}/bin/mount";
      };

  shellFor = variant: if variant == "initrd" then "/bin/sh" else pkgs.runtimeShell;

  # where the root is while these commands run: "/sysroot" from an initrd, before switch_root,
  # and "" against a root that is already mounted.
  prefixFor = variant: if variant == "initrd" then "/sysroot" else "";

  lookupUid = name: config.users.users.${name}.uid or null;
  lookupGid = name: config.users.groups.${name}.gid or null;

  ids = {
    uid = name: if lookupUid name == null then name else toString (lookupUid name);
    gid = name: if lookupGid name == null then name else toString (lookupGid name);
  };

  # finix gives every neededForBoot filesystem its own initrd mount task, named
  # after the mountpoint it mounts. these two mirror `escapePath` and the
  # prefix test in finix's `modules/lib/utils.nix` and `modules/finit/mount.nix`
  # respectively; they are duplicated rather than imported because this module
  # is evaluated as a plain nixos module and has no access to finix's `utils`.
  escapePath =
    s: if s == "/" then "root" else lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" s);

  # "/nix" precedes "/nix/store" but not "/nixos"; "/" precedes everything
  pathIsPrefix = a: b: a == b || a == "/" || lib.hasPrefix (a + "/") b;

  bootFilesystems = lib.filter (fs: fs.neededForBoot) (lib.attrValues config.fileSystems);

  # the mountpoint a path resolves through, i.e. the deepest mountpoint that
  # prefixes it. `persistentStoragePath` is not required to be a mountpoint
  # itself - it is allowed to sit inside one - so this cannot just escape the
  # path directly.
  mountPointFor =
    path:
    let
      candidates = lib.filter (fs: pathIsPrefix fs.mountPoint path) bootFilesystems;
      deepestFirst = lib.sort (
        a: b: builtins.stringLength a.mountPoint > builtins.stringLength b.mountPoint
      ) candidates;
    in
    if candidates == [ ] then null else (lib.head deepestFirst).mountPoint;

  # an entry may only be set up once every volume it touches is mounted: the one
  # backing the persistent copies, and the ones its mountpoints live on.
  conditionsFor =
    stateConfig:
    let
      paths = [
        stateConfig.persistentStoragePath
      ]
      ++ map (d: d.directory) (getAllDirectories stateConfig)
      ++ map (f: f.file) (getAllFiles stateConfig);
      mountPoints = lib.unique (lib.filter (m: m != null) (map mountPointFor paths));
    in
    lib.concatMapStringsSep "," (m: "task/mount-${escapePath m}/success") (
      lib.sort (a: b: a < b) mountPoints
    );

  # one unit per `preserveAt` entry, so each volume is set up as soon as it is
  # available instead of every entry waiting on the slowest one.
  #
  # Taken as a function of the variant - "initrd" or "stage2" - because everything that differs
  # between the two places this runs is a property of the boot path and not of the entry: where
  # the root is, how commands are named, and which interpreter exists. Deriving all three from
  # the one argument is the point: they were a prefix and a shared command set before, so a
  # change that was right for one place silently applied to the other.
  #
  # Whether an entry has any commands at all does not depend on the variant, so either set
  # answers the "is anything configured" question below.
  entriesFor =
    variant:
    lib.filter (e: e.cmds != [ ]) (
      lib.mapAttrsToList (name: stateConfig: {
        inherit stateConfig;
        unit = "preservation-${escapePath stateConfig.persistentStoragePath}";
        cmds = mkMountCmds (commandsFor variant) ids (prefixFor variant) name stateConfig;
      }) cfg.preserveAt
    );

  entries = entriesFor "initrd";

  # a preserved path that cannot be set up is a bad reason to refuse to boot, so
  # every entry is guarded (see `guard` in lib.nix) and this script always exits
  # 0. the cost is that failures are only ever reported, never enforced - hence
  # writing to the console directly, so the warning is visible even though finit
  # is told the task succeeded.
  # `#!` the same way the commands are named, which `shellFor` decides: a store path for stage
  # 2, where nothing guarantees /bin/sh before activation, and /bin/sh in the initrd, where a
  # store path would not survive being copied into the image. See `commandsFor`.
  #
  # `writeScript` rather than `writeShellScript`, so the body below - which is POSIX and says so
  # where it reasons about errexit - keeps its own `#!` line and its own preamble.
  mkScript =
    variant: entry:
    pkgs.writeScript "${entry.unit}-${variant}" ''
      #!${shellFor variant}
      preservation_warn() {
        msg="preservation: failed to set up $1, continuing without it"
        echo "$msg" >&2
        if [ -w /dev/console ]; then echo "$msg" > /dev/console; fi
        return 0
      }

      ${lib.concatStringsSep "\n" entry.cmds}

      exit 0
    '';

in
{
  imports = [
    ./options.nix
  ];

  config = lib.mkIf (cfg.enable && entries != [ ]) {
    # Where the work happens depends on whether there is an initrd to do it in.
    #
    # With one, it belongs there: bind mounts made before switch_root survive it, so every
    # preserved path is in place from the very first moment of stage 2 - including the ones
    # stage 2 itself reads, like /etc/machine-id.
    #
    # Without one there is no earlier place to stand, and the whole module used to write only
    # into `boot.initrd.contents` - so on a machine with `boot.initrd.enable = false`, which
    # finix supports and tests three ways, none of this was assembled. No script, no stanza, no
    # bind mounts: `preservation.enable = true` evaluated cleanly and preserved nothing.
    #
    # The same commands run against the already-mounted root as a unit at the head of the
    # trunk: after `mount-filesystems`, because the preserved root has to be mounted first,
    # and named on `start` so the `sysinit` anchor waits for it and everything attached to any
    # later level is behind it.
    assertions = lib.optionals config.boot.initrd.enable (
      map (entry: {
        assertion = conditionsFor entry.stateConfig != "";
        message = ''
          preservation: no `neededForBoot` filesystem provides
          "${entry.stateConfig.persistentStoragePath}". The preserved paths are set
          up from the initrd, so the volume holding them has to be mounted there -
          set `fileSystems."<mountpoint>".neededForBoot = true`.
        '';
      }) entries
    );

    boot.initrd.contents = lib.mkIf config.boot.initrd.enable (
      lib.concatMap (entry: [
        {
          target = "/usr/local/bin/${entry.unit}";
          source = mkScript "initrd" entry;
        }
        {
          target = "/etc/finit.d/${entry.unit}.conf";
          source = pkgs.writeText "${entry.unit}-finit-initrd.conf" ''
            run [S] name:${entry.unit} <${conditionsFor entry.stateConfig}> ${entry.unit}
          '';
        }
      ]) entries
    );

    # one unit per entry here too, for the reason the initrd has one script per entry: a volume
    # that is ready should not wait on one that is not.
    providers.services.units = lib.mkIf (!config.boot.initrd.enable) (
      lib.listToAttrs (
        map (
          entry:
          lib.nameValuePair entry.unit {
            description = "mount preserved state on ${entry.stateConfig.persistentStoragePath}";

            requires = [
              "start"
              "mount-filesystems"
            ];

            type.oneshot.command = toString (mkScript "stage2" entry);
          }
        ) (entriesFor "stage2")
      )
    );
  };
}
