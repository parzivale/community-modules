# agenix for finix
#
# The decrypt-at-boot half of agenix, ported from its NixOS module
# (ryantm/agenix, modules/age.nix @ 9ba0d85) onto `providers.services`. Only that half
# needed porting: the option surface and the shell that installs a generation
# are class-neutral, and what was NixOS-only was `systemd.services
# .agenix-install-secrets` plus an activation-script fallback for systems
# without sysusers. finix has neither, so the work is one oneshot unit.
#
# agenix-rekey's own module (oddlama/agenix-rekey, modules/agenix-rekey.nix)
# needs no port at all — it touches no systemd, no activation scripts and
# carries no `_class`, so it composes on top of this as it does on NixOS.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.age;

  users = config.users.users;

  # The host keys sshd is actually configured with - which is what NixOS derives
  # this from too, by way of `services.openssh.hostKeys`. finix says the same
  # thing as an sshd_config key, so reading the setting rather than naming a path
  # means this follows `services.openssh.hostKeyPath` wherever a host puts it.
  defaultIdentityPaths = lib.optionals (config.services.openssh.enable or false) (
    config.services.openssh.settings.HostKey or [ ]
  );

  mountCommand = ''
    grep -q "${cfg.secretsMountPoint} ramfs" /proc/mounts ||
      mount -t ramfs none "${cfg.secretsMountPoint}" -o nodev,nosuid,mode=0751
  '';

  newGeneration = ''
    _agenix_generation="$(basename "$(readlink ${cfg.secretsDir})" || echo 0)"
    (( ++_agenix_generation ))
    echo "[agenix] creating new generation in ${cfg.secretsMountPoint}/$_agenix_generation"
    mkdir -p "${cfg.secretsMountPoint}"
    chmod 0751 "${cfg.secretsMountPoint}"
    ${mountCommand}
    mkdir -p "${cfg.secretsMountPoint}/$_agenix_generation"
    chmod 0751 "${cfg.secretsMountPoint}/$_agenix_generation"
  '';

  chownMountPoint = ''
    chown :${cfg.keysGroup} "${cfg.secretsMountPoint}" "${cfg.secretsMountPoint}/$_agenix_generation"
  '';

  setTruePath =
    secretType:
    if secretType.symlink then
      ''_truePath="${cfg.secretsMountPoint}/$_agenix_generation/${secretType.name}"''
    else
      ''_truePath="${secretType.path}"'';

  installSecret = secretType: ''
    (
    ${setTruePath secretType}
    echo "decrypting '${secretType.file}' to '$_truePath'..."
    TMP_FILE="$_truePath.tmp"

    IDENTITIES=()
    for identity in ${toString cfg.identityPaths}; do
      test -r "$identity" || continue
      test -s "$identity" || continue
      IDENTITIES+=(-i)
      IDENTITIES+=("$identity")
    done

    test "''${#IDENTITIES[@]}" -eq 0 && echo "[agenix] WARNING: no readable identities found!"

    mkdir -p "$(dirname "$_truePath")"
    [ "${secretType.path}" != "${cfg.secretsDir}/${secretType.name}" ] && mkdir -p "$(dirname "${secretType.path}")"
    (
      umask u=r,g=,o=
      test -f "${secretType.file}" || echo '[agenix] WARNING: encrypted file ${secretType.file} does not exist!'
      test -d "$(dirname "$TMP_FILE")" || echo "[agenix] WARNING: $(dirname "$TMP_FILE") does not exist!"
      LANG=${
        config.i18n.defaultLocale or "C"
      } ${cfg.ageBin} --decrypt "''${IDENTITIES[@]}" -o "$TMP_FILE" "${secretType.file}"
    )
    chmod ${secretType.mode} "$TMP_FILE"
    mv -f "$TMP_FILE" "$_truePath"

    ${lib.optionalString secretType.symlink ''
      [ "${secretType.path}" != "${cfg.secretsDir}/${secretType.name}" ] && ln -sfT "${cfg.secretsDir}/${secretType.name}" "${secretType.path}"
    ''}
    ) &
  '';

  testIdentities = map (path: ''
    test -f ${path} || echo '[agenix] WARNING: config.age.identityPaths entry ${path} not present!'
  '') cfg.identityPaths;

  cleanupAndLink = ''
    _agenix_generation="$(basename "$(readlink ${cfg.secretsDir})" || echo 0)"
    (( ++_agenix_generation ))
    echo "[agenix] symlinking new secrets to ${cfg.secretsDir} (generation $_agenix_generation)..."
    ln -sfT "${cfg.secretsMountPoint}/$_agenix_generation" ${cfg.secretsDir}

    (( _agenix_generation > 1 )) && {
    echo "[agenix] removing old secrets (generation $(( _agenix_generation - 1 )))..."
    rm -rf "${cfg.secretsMountPoint}/$(( _agenix_generation - 1 ))"
    }
  '';

  chownSecret = secretType: ''
    ${setTruePath secretType}
    chown ${secretType.owner}:${secretType.group} "$_truePath"
  '';

  installSecrets = lib.concatStringsSep "\n" (
    [ "echo '[agenix] decrypting secrets...'" ]
    ++ testIdentities
    ++ map installSecret (builtins.attrValues cfg.secrets)
    ++ [ "wait" ]
    ++ [ cleanupAndLink ]
  );

  chownSecrets = lib.concatStringsSep "\n" (
    [ "echo '[agenix] chowning...'" ]
    ++ [ chownMountPoint ]
    ++ map chownSecret (builtins.attrValues cfg.secrets)
  );

  # The NixOS unit gets `mount` from `path = [ pkgs.mount ]`. A unit here runs
  # with whatever the supervisor hands it, so name the tools instead of hoping.
  installScript = pkgs.writeShellScript "agenix-install-secrets" ''
    export PATH="${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.util-linux
      ]
    }:$PATH"

    ${newGeneration}
    ${installSecrets}
    ${chownSecrets}
  '';

  secretType = lib.types.submodule (
    { config, ... }:
    {
      options = {
        name = lib.mkOption {
          type = lib.types.str;
          default = config._module.args.name;
          defaultText = lib.literalExpression "config._module.args.name";
          description = ''
            Name of the file used in {option}`age.secretsDir`.
          '';
        };

        file = lib.mkOption {
          type = lib.types.path;
          description = ''
            Age file the secret is loaded from.
          '';
        };

        path = lib.mkOption {
          type = lib.types.str;
          default = "${cfg.secretsDir}/${config.name}";
          defaultText = lib.literalExpression ''"''${cfg.secretsDir}/''${config.name}"'';
          description = ''
            Path where the decrypted secret is installed.
          '';
        };

        mode = lib.mkOption {
          type = lib.types.str;
          default = "0400";
          description = ''
            Permissions mode of the decrypted secret, in a format understood by chmod.
          '';
        };

        owner = lib.mkOption {
          type = lib.types.str;
          default = "0";
          description = ''
            User of the decrypted secret.
          '';
        };

        group = lib.mkOption {
          type = lib.types.str;
          default = users.${config.owner}.group or "0";
          defaultText = lib.literalExpression ''users.''${config.owner}.group or "0"'';
          description = ''
            Group of the decrypted secret.
          '';
        };

        symlink = lib.mkEnableOption "symlinking secrets to their destination" // {
          default = true;
        };
      };
    }
  );
in
{
  options.age = {
    ageBin = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.age}/bin/age";
      defaultText = lib.literalExpression ''"''${pkgs.age}/bin/age"'';
      description = ''
        The age executable to use.
      '';
    };

    secrets = lib.mkOption {
      type = lib.types.attrsOf secretType;
      default = { };
      description = ''
        Attrset of secrets. Nothing is installed while this is empty, and the
        unit is not declared at all.
      '';
    };

    secretsDir = lib.mkOption {
      type = lib.types.path;
      default = "/run/agenix";
      description = ''
        Folder where secrets are symlinked to.
      '';
    };

    secretsMountPoint = lib.mkOption {
      type =
        lib.types.addCheck lib.types.str (
          s: (builtins.match "[ \t\n]*" s) == null && (builtins.match ".+/" s) == null
        )
        // {
          description = "${lib.types.str.description} (with check: non-empty without trailing slash)";
        };
      default = "/run/agenix.d";
      description = ''
        Where secrets are created before they are symlinked to {option}`age.secretsDir`.
      '';
    };

    identityPaths = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = defaultIdentityPaths;
      defaultText = lib.literalExpression ''
        config.services.openssh.settings.HostKey when `services.openssh.enable`, else [ ]
      '';
      description = ''
        Paths to keys used as identities in age decryption.
      '';
    };

    keysGroup = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = ''
        Group owning {option}`age.secretsMountPoint` and the current generation.

        NixOS uses `keys` here, a group nixpkgs creates for the purpose. finix
        declares no such group, so this defaults to `root` and chowning cannot
        fail on a fresh system. Point it at a group of your own if unprivileged
        services need to traverse the mount point.
      '';
    };
  };

  config = lib.mkIf (cfg.secrets != { }) {
    assertions = [
      {
        assertion = cfg.identityPaths != [ ];
        message = "age.identityPaths must be set, for example to the host's ssh host key.";
      }
    ];

    providers.services.units.agenix-install-secrets = {
      description = "decrypt agenix secrets into ${cfg.secretsDir}";

      # The sysinit tier: secrets exist before anything that might read them,
      # and accounts already exist because finix creates them in
      # `system.activation.scripts.users`, which runs before any unit starts —
      # so the chowns have users to name. A service needing a secret should
      # require this unit directly rather than lean on the tier.
      #
      # `ssh-keygen` as well, where there is one, because the identity this decrypts with is the
      # machine's ssh host key - see the note on `identityPaths` above. Both units attach to the
      # same tier, and a tier starts together, so without this edge the two race. It is not a
      # theoretical race: on a first boot there is no key yet, and losing means exiting 1, which
      # leaves this unit's readiness companion waiting for a success that never comes and stalls
      # `sysinit` with the entire trunk behind it.
      requires = [
        "sysinit"
      ]
      ++ lib.optional (config.services.openssh.enable or false) "ssh-keygen";

      type.oneshot.command = installScript;
    };
  };
}
