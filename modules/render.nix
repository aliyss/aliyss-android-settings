# render.nix — the pure half of the home-manager module.
#
# These functions turn `aliyss.androidSettings` into the text the engine
# consumes: a manifest, one env file per hook, and the hook name list. They are
# split out of the module (and take `lib` as an argument) so they can be tested
# without home-manager: `checks.render` in flake.nix pins the exact text for a
# reference configuration, which is what protects the quoting rules below — the
# part of the module that is easiest to get subtly wrong and hardest to notice.
{ lib }: rec {
  # `toString` is wrong for two of the types this module accepts:
  #   - floats render as "1.000000", while Android stores whatever string it is
  #     handed and `verify` compares that string literally — so they are written
  #     the way the props files spell them ("0.75", "1.0"). JSON gives that;
  #   - bools render as "" / "1", so `false` would write an empty value (and an
  #     empty hook env var) instead of the `0` the props files and hooks use.
  toStr = value:
    if builtins.isBool value
    then if value then "1" else "0"
    else if builtins.isFloat value
    then builtins.toJSON value
    else toString value;

  # A `props` entry is one manifest line. Most are `namespace.key = value`, but
  # the engine's other line forms need help:
  #   - a list value is comma-joined, which is the syntax `qs.add`/`qs.remove`
  #     take (`qs.add = flashlight,screenrecord`);
  #   - the key "cmd:" holds raw root commands, each rendered as its own
  #     `cmd:...` line, for the toggles `settings put` cannot drive
  #     (`svc wifi enable`, ...).
  propLine = key: value:
    if key == "cmd:"
    then map (cmd: "cmd:${toStr cmd}") (lib.toList value)
    else [
      "${key} = ${
        if builtins.isList value
        then lib.concatMapStringsSep "," toStr value
        else toStr value
      }"
    ];

  # The whole manifest, one line per entry, attrs sorted by name.
  manifestText = props:
    lib.concatLines (lib.concatLists (lib.mapAttrsToList propLine props));

  # One `<hook>.env` per hookConfig entry, keyed by hook name. Values are
  # shell-quoted because the hook sources this file (`set -a; . env`), and a raw
  # `ACTION=cmd with spaces` would run cmd at source time.
  hookEnvTexts = hookConfig:
    lib.mapAttrs (
      name: env:
      lib.concatLines (
        lib.mapAttrsToList (key: value: "${key}=${lib.escapeShellArg (toStr value)}") env
      )
    ) hookConfig;

  # The engine's `sync-hooks` takes the hook list as arguments.
  hookNames = hooks: lib.concatStringsSep " " hooks;
}
