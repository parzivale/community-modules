# cgroups, declared without naming an init
#
# A machine's cgroup layout is not part of the `providers.services` contract:
# units say what runs and what they wait for, not how the kernel accounts for
# them. But a cgroup is not init-specific either — it is a kernel object with
# controller settings — so a module that wants one should not have to name
# finit to get it.
#
# This is the option surface for that, with the lowering kept separate per
# backend. finit is the only one implemented, because it is the only backend
# that creates cgroups declaratively today; on anything else, asking for one is
# an assertion rather than silence.
{
  config,
  lib,
  ...
}:
let
  cfg = config.cgroups;
in
{
  options.cgroups = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              default = name;
              description = ''
                Name of the cgroup to create.
              '';
            };

            settings = lib.mkOption {
              type =
                with lib.types;
                attrsOf (oneOf [
                  int
                  str
                ]);
              default = { };
              example = lib.literalExpression ''{ "cpu.weight" = 100; }'';
              description = ''
                Controller settings for the cgroup, as attribute-file names and
                the values written into them.
              '';
            };
          };
        }
      )
    );
    default = { };
    description = ''
      cgroups (v2) to create at boot, keyed by name.
    '';
  };

  config = lib.mkIf (cfg != { }) {
    assertions = [
      {
        assertion = config.providers.services.backend == "finit";
        message = ''
          `cgroups` is only implemented for the finit backend, which is the only
          init here that creates cgroups declaratively. Drop the option, or set
          the controller values another way on ${config.providers.services.backend}.
        '';
      }
    ];

    finit.cgroups = lib.mapAttrs (_: group: { inherit (group) name settings; }) cfg;
  };
}
