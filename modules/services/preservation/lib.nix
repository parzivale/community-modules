{ lib, ... }:
rec {
  # concatenates two paths
  # inserts a "/" in between if there is none, removes one if there are two
  concatTwoPaths =
    parent: child:
    with lib.strings;
    if hasSuffix "/" parent then
      if
        hasPrefix "/" child
      # "/parent/" "/child"
      then
        parent + (removePrefix "/" child)
      # "/parent/" "child"
      else
        parent + child
    else if
      hasPrefix "/" child
    # "/parent" "/child"
    then
      parent + child
    # "/parent" "child"
    else
      parent + "/" + child;

  # concatenates a list of paths using `concatTwoPaths`
  concatPaths = builtins.foldl' concatTwoPaths "";

  # get the parent directory of an absolute path
  parentDirectory =
    path:
    with lib.strings;
    assert "/" == (builtins.substring 0 1 path);
    let
      parts = splitString "/" (removeSuffix "/" path);
      len = builtins.length parts;
    in
    if len < 1 then "/" else concatPaths ([ "/" ] ++ (lib.lists.sublist 0 (len - 1) parts));

  # every directory strictly between `boundary` and `path`, outermost first, with neither end
  # included. The boundary is a path that already exists and is already owned correctly; the
  # result is what `mkdir -p` would have had to create to reach `path`.
  ancestorsBetween =
    boundary: path:
    let
      base = lib.removeSuffix "/" boundary;
      parts = builtins.filter (p: p != "") (
        lib.splitString "/" (lib.removePrefix base (lib.removeSuffix "/" path))
      );
      n = builtins.length parts;
    in
    map (i: concatPaths ([ base ] ++ (lib.lists.sublist 0 (i + 1) parts))) (lib.lists.range 0 (n - 2));

  getUserDirectories = lib.mapAttrsToList (_: userConfig: userConfig.directories);
  getUserFiles = lib.mapAttrsToList (_: userConfig: userConfig.files);

  getAllDirectories =
    stateConfig:
    stateConfig.directories ++ (builtins.concatLists (getUserDirectories stateConfig.users));

  getAllFiles =
    stateConfig: stateConfig.files ++ (builtins.concatLists (getUserFiles stateConfig.users));

  # produces the shell commands for all bind mounts and symlinks of one preserved root.
  #
  # `prefix` is where that root is mounted when the commands run: "/sysroot" in an initrd,
  # where doing the work before switch_root means the paths are available from the very start
  # of stage 2, and "" on a machine with no initrd, where the root is already the root and the
  # same commands run against it directly. Symlink targets are never prefixed - they are
  # resolved in the final namespace either way.
  mkMountCmds =
    ids: prefix: _preserveAt: stateConfig:
    let
      allDirectories = getAllDirectories stateConfig;
      allFiles = getAllFiles stateConfig;
      bindmountDirs = builtins.filter (d: d.how == "bindmount") allDirectories;
      symlinkDirs = builtins.filter (d: d.how == "symlink") allDirectories;
      bindmountFiles = builtins.filter (f: f.how == "bindmount") allFiles;
      symlinkFiles = builtins.filter (f: f.how == "symlink") allFiles;

      par = cmds: "( ${lib.concatStringsSep "; " cmds} ) &";

      # The options carry ownership for a preserved path and for the parent that has to be
      # made to hold it, and nothing was applying either: every directory arrived through
      # `mkdir -p` or `mount --mkdir`, which run as root here - in the initrd, before there is
      # a session or a login - so a user's own directories came out owned by root.
      #
      # /home/bella/.config is the case that shows it. It exists only because something
      # preserved a path inside it, so nothing else creates it and nothing else chowns it;
      # the user's home is made by tmpfiles and this is one level below that. A compositor
      # then cannot write its own configuration into its own home.
      # Numeric ids, not names. These commands run in the initrd, which carries no /etc/passwd
      # and no /etc/group - so `chown bella:users` there cannot resolve either name and fails,
      # inside a backgrounded subshell whose status nothing checks. Every preserved path of
      # every user stayed root-owned and nothing said so.
      #
      # `root:root` kept working throughout, which is why only the users' own paths were wrong,
      # and why this took a while to see. What it breaks first is nix: an unprivileged user
      # cannot create ~/.local/state/nix underneath a root-owned ~/.local, so `nix-env` fails,
      # so home-manager cannot find a profile directory, so activation stops before it links
      # anything. Which presents as a compositor starting with no configuration at all.
      own = entry: path: [
        "chown ${ids entry} ${path}"
        "chmod ${entry.mode} ${path}"
      ];

      # Every directory created on the way to a preserved path, not only the last one.
      # `mkdir -p` makes them all as root, and chowning just the immediate parent corrected
      # ~/.local/state while leaving ~/.local itself - which is enough for everything above.
      #
      # A user's entry carries the home its path is relative to, and that home is the boundary:
      # it is made by tmpfiles and already owned correctly. Entries that are not a user's keep
      # the single-parent behaviour, because /var and / are not this module's to reassign.
      createdParents =
        entry: path:
        if entry ? ownFrom then
          ancestorsBetween (concatPaths [
            prefix
            entry.ownFrom
          ]) path
        else
          [ (parentDirectory path) ];

      dirCmds = map (
        dirConfig:
        let
          persistentPath = concatPaths [
            prefix
            stateConfig.persistentStoragePath
            dirConfig.directory
          ];
          volatilePath = concatPaths [
            prefix
            dirConfig.directory
          ];
        in
        par (
          [
            "mkdir -p ${persistentPath}"
            "mount --mkdir --bind ${persistentPath} ${volatilePath}"
          ]
          ++ lib.concatMap (own dirConfig.parent) (createdParents dirConfig volatilePath)
          ++ own dirConfig volatilePath
        )
      ) bindmountDirs;

      symlinkDirCmds = map (
        dirConfig:
        let
          persistentPath = concatPaths [
            prefix
            stateConfig.persistentStoragePath
            dirConfig.directory
          ];
          volatilePath = concatPaths [
            prefix
            dirConfig.directory
          ];
          target = concatPaths [
            stateConfig.persistentStoragePath
            dirConfig.directory
          ];
        in
        par (
          lib.optionals dirConfig.createLinkTarget (
            [ "mkdir -p ${persistentPath}" ] ++ own dirConfig persistentPath
          )
          ++ [ "mkdir -p ${parentDirectory volatilePath}" ]
          ++ lib.concatMap (own dirConfig.parent) (createdParents dirConfig volatilePath)
          ++ [ "ln -sf ${target} ${volatilePath}" ]
        )
      ) symlinkDirs;

      fileCmds = map (
        fileConfig:
        let
          persistentPath = concatPaths [
            prefix
            stateConfig.persistentStoragePath
            fileConfig.file
          ];
          volatilePath = concatPaths [
            prefix
            fileConfig.file
          ];
        in
        par (
          [
            "mkdir -p ${parentDirectory persistentPath}"
            "touch ${persistentPath}"
            "mkdir -p ${parentDirectory volatilePath}"
          ]
          ++ lib.concatMap (own fileConfig.parent) (createdParents fileConfig volatilePath)
          ++ [
            "touch ${volatilePath}"
            "mount --bind ${persistentPath} ${volatilePath}"
          ]
          ++ own fileConfig persistentPath
        )
      ) bindmountFiles;

      symlinkFileCmds = map (
        fileConfig:
        let
          persistentPath = concatPaths [
            prefix
            stateConfig.persistentStoragePath
            fileConfig.file
          ];
          volatilePath = concatPaths [
            prefix
            fileConfig.file
          ];
          target = concatPaths [
            stateConfig.persistentStoragePath
            fileConfig.file
          ];
        in
        par (
          lib.optionals fileConfig.createLinkTarget [ "touch ${persistentPath}" ]
          ++ [
            "mkdir -p ${parentDirectory volatilePath}"
            "ln -sf ${target} ${volatilePath}"
          ]
        )
      ) symlinkFiles;
    in
    dirCmds ++ symlinkDirCmds ++ fileCmds ++ symlinkFileCmds ++ [ "wait" ];
}
