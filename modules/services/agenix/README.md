# agenix

Age-encrypted secrets for finix, decrypted into a tmpfs generation at boot.

Ported from [agenix](https://github.com/ryantm/agenix)'s NixOS module
(`modules/age.nix`, rev `9ba0d85de3eaa7afeab493fed622008b6e4924f5`). The option surface and the shell that
installs a generation are unchanged; what was NixOS-only — a
`systemd.services.agenix-install-secrets` unit, plus an activation-script
fallback for systems without sysusers — is one `providers.services` oneshot
here, so it works under any init finix can select rather than finit alone.

## Basic usage

```nix
{
  age = {
    identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    secrets.wireguard = {
      file = ./secrets/wireguard.age;
      owner = "systemd-network";
      mode = "0440";
    };
  };
}
```

A service that needs a secret should require the unit rather than lean on the
tier it attaches to:

```nix
{
  providers.services.units.my-service.requires = [ "agenix-install-secrets" ];
}
```

## Boot ordering

The unit attaches to `sysinit`, so secrets exist before the basic tier comes
up. It needs no ordering against account creation: finix creates users in
`system.activation.scripts.users`, which has already run by the time any unit
starts, so the `chown` of each secret has users to name.

## agenix-rekey

[agenix-rekey](https://github.com/oddlama/agenix-rekey) composes on top of this
unmodified — its module touches no systemd, no activation scripts and carries
no `_class`, so the same
`import agenix-rekey/modules/agenix-rekey.nix nixpkgs` you would use on NixOS
works here. It only needs `age.secrets` to exist, which this module provides:

```nix
{
  imports = [ (import "${agenix-rekey}/modules/agenix-rekey.nix" nixpkgs) ];

  age.rekey = {
    hostPubkey = "ssh-ed25519 AAAA...";
    masterIdentities = [ ./yubikey.pub ];
    storageMode = "local";
    localStorageDir = ./secrets/rekeyed/myhost;
  };

  age.secrets.wireguard.rekeyFile = ./secrets/wireguard.age;
}
```

The `agenix` CLI is driven from the flake, not from here.

## Differences from NixOS

- **`age.keysGroup`** — NixOS chowns the mount point to `keys`, a group nixpkgs
  creates. finix declares no such group, so this defaults to `root`. Point it
  at a group of your own if unprivileged services need to traverse the mount
  point.
- **`age.identityPaths`** — same idea as NixOS, read from a different place.
  NixOS derives the default from `services.openssh.hostKeys`; finix says the
  same thing as the `HostKey` sshd_config setting, so the default here is
  `config.services.openssh.settings.HostKey` when `services.openssh.enable` is
  set, and `[ ]` otherwise. That follows `services.openssh.hostKeyPath`, so a
  host which moves its key does not have to repeat itself here.
- **Darwin** — dropped. The upstream module branches throughout on
  `isDarwin`; none of it applies here.
