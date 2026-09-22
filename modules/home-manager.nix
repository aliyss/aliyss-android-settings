# home-manager module — the "service" half of this flake, next to the package.
#
# There is no systemd on the phone: the hooks ARE termux-services (runit)
# services, created by the engine's `install-hook`, and runit autostarts them at
# Termux boot (no `down` file). So the module's job is declarative glue that runs
# on every switch:
#
#   1. render `props` to a manifest and `android-settings apply` it (safe to
#      re-run: every line is written again);
#   2. `android-settings sync-hooks` the declared `hooks` — install new/changed,
#      remove undeclared, leave unchanged ones running, env from `hookConfig`.
#
# Nothing happens unless `enable` is set, and a hook that is not declared is
# never installed: the package ships every hook as *available*.
#
# The flake binds `self` so `package` defaults to this repo's own build:
#   homeModules.default = import ./modules/home-manager.nix { inherit self; };
{ self }: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.aliyss.androidSettings;

  # `toString` is wrong for two of the types this module accepts:
  #   - floats render as "1.000000", while Android stores whatever string it is
  #     handed and `verify` compares that string literally — so they are written
  #     the way the props files spell them ("0.75", "1.0"). JSON gives that and
  #     shortens "0.750000" to "0.75";
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
  #     (`svc wifi enable`, `svc data disable`, ...).
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

  manifest = pkgs.writeText "android-settings.props" (
    lib.concatLines (lib.concatLists (lib.mapAttrsToList propLine cfg.props))
  );

  # One `<hook>.env` per hookConfig entry, in the store. Values are shell-quoted
  # because the hook sources this file (`set -a; . env`), and a raw
  # `ACTION=cmd with spaces` would run cmd at source time.
  hookEnvFiles = lib.mapAttrs (
    name: env:
      pkgs.writeText "android-settings-${name}.env" (
        lib.concatLines (
          lib.mapAttrsToList (key: value: "${key}=${lib.escapeShellArg (toStr value)}") env
        )
      )
  ) cfg.hookConfig;

  hookEnvDir = pkgs.linkFarm "android-settings-hookenv" (
    lib.mapAttrsToList (name: path: {
      inherit path;
      name = "${name}.env";
    }) hookEnvFiles
  );

  hookNames = lib.concatStringsSep " " cfg.hooks;
in {
  options.aliyss.androidSettings = {
    enable = lib.mkEnableOption "declarative Android settings and hook services";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.android-settings;
      defaultText = lib.literalExpression "aliyss-android-settings.packages.\${system}.android-settings";
      description = "Engine + hook pack + settings library to use.";
    };

    props = lib.mkOption {
      type = lib.types.attrsOf (lib.types.oneOf [
        lib.types.str
        lib.types.int
        lib.types.float
        lib.types.bool
        (lib.types.listOf (lib.types.oneOf [
          lib.types.str
          lib.types.int
        ]))
      ]);
      default = {};
      example = lib.literalExpression ''
        {
          "global.window_animation_scale" = 0.75;
          "secure.night_display_enabled" = 1;
          "qs.add" = [ "flashlight" "screenrecord" ];
          "cmd:" = [ "svc wifi enable" ];
        }
      '';
      description = ''
        Settings to write as `namespace.key = value` (`global`, `system` or
        `secure`), rendered to a manifest and applied on every switch. `apply`
        writes every line — harmless to repeat — while `android-settings
        verify` reads the keys back and reports drift.

        Floats are written the way the props files spell them (`0.75`). A list
        value is comma-joined, for `qs.add` / `qs.remove`. Raw root commands —
        for toggles `settings put` cannot drive, like `svc wifi enable` — go
        under the `"cmd:"` key, one manifest `cmd:` line each.
      '';
    };

    hooks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["battery-low" "net-watch"];
      description = ''
        Hook services to run, managed by `android-settings sync-hooks`:
        declaring one installs it (which is what creates the runit service),
        anything not listed here is removed, and an unchanged hook is left
        running. `android-settings list-hooks` shows what the package offers.
      '';
    };

    hookConfig = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.oneOf [
        lib.types.str
        lib.types.int
        lib.types.float
        lib.types.bool
      ]));
      default = {};
      example = lib.literalExpression ''{ "net-watch" = { CHECK_INTERVAL = "60"; }; }'';
      description = ''
        Per-hook environment, overriding the hook's own `defaults`. Values are
        shell-quoted when written, so an `ACTION` with spaces stays one word.
        Changing one reinstalls that hook, which restarts its service on the
        next switch.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [cfg.package];

    # Failure here is a warning, not a switch failure: a missing root grant (or
    # anything the engine refuses) should not cost you a generation. The engine
    # reports per-line detail, so re-running it by hand shows exactly what broke.
    home.activation.android-settings = lib.hm.dag.entryAfter ["writeBoundary"] (
      lib.optionalString (cfg.props != {}) ''
        $DRY_RUN_CMD ${cfg.package}/bin/android-settings apply ${manifest} \
          || echo "android-settings: applying props failed — run 'android-settings verify' to see why" >&2
      ''
      + lib.optionalString (cfg.hooks != [] || cfg.hookConfig != {}) ''
        $DRY_RUN_CMD ${cfg.package}/bin/android-settings sync-hooks --env-dir ${hookEnvDir} ${hookNames} \
          || echo "android-settings: hook sync failed — run 'android-settings list-hooks' to see why" >&2
      ''
    );
  };
}
