# home-manager module — the "service" half of this flake, next to the package.
#
# There is no systemd on the phone: the hooks ARE termux-services (runit)
# services, created by the engine's `install-hook`, and runit autostarts them at
# Termux boot (no `down` file). So the module's job is declarative glue that runs
# on every switch:
#
#   1. render `props` to a manifest and `android-settings apply` it (every line
#      is written again — harmless; `verify` is what reads the keys back, and the
#      props-watch hook can re-apply on drift without a switch);
#   2. `android-settings sync-hooks` the declared `hooks` — install new/changed,
#      remove undeclared, leave unchanged ones running, env from `hookConfig`.
#
# Nothing happens unless `enable` is set, and a hook that is not declared is
# never installed: the package ships every hook as *available*.
#
# The flake binds `self` so `package` defaults to this repo's own build:
#   homeModules.default = import ./modules/home-manager.nix { inherit self; };
#
# The pure text rendering lives in ./render.nix, which flake.nix's `checks.render`
# tests against golden files.
{ self }: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.aliyss.androidSettings;

  render = import ./render.nix {inherit lib;};

  manifest = pkgs.writeText "android-settings.props" (render.manifestText cfg.props);

  hookEnvFiles = lib.mapAttrs (
    name: text: pkgs.writeText "android-settings-${name}.env" text
  ) (render.hookEnvTexts cfg.hookConfig);

  hookEnvDir = pkgs.linkFarm "android-settings-hookenv" (
    lib.mapAttrsToList (name: path: {
      inherit path;
      name = "${name}.env";
    }) hookEnvFiles
  );

  hookNames = render.hookNames cfg.hooks;
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

        `android-settings lint` checks all of this offline, before a switch.
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

        Keys must be valid shell names (the file is sourced): a key like
        `08:00` cannot be expressed — the `schedule` hook takes `HH:MM|command`
        entries in a single `SCHEDULES` value instead.
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
