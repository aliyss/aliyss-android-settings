{
  description =
    "aliyss-android-settings — declarative Android settings + hook services for the aliyss phone (package + home-manager module in one flake)";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = ["aarch64-linux" "x86_64-linux"];
    forAllSystems = f:
      builtins.listToAttrs (map (system: {
        name = system;
        value = f system;
      })
      systems);

    # The service half of the flake, next to the package above — same split as
    # mako in nixpkgs. `self` is bound here so the module can default its
    # `package` option to this flake's own build, rather than making every
    # consumer pass a store path. The module itself pulls no nixpkgs version of
    # its own: it extends the consumer's pkgs/lib.
    homeModule = import ./modules/home-manager.nix {inherit self;};

    # The module's pure text rendering, shared with the render check below.
    renderFor = pkgs: import ./modules/render.nix {inherit (pkgs) lib;};
  in {
    homeModules = {
      default = homeModule;
      android-settings = homeModule;
    };

    # NOTE: deliberately not aliased as `homeManagerModules`. Home-manager's
    # own flake exports `nixosModules`/`darwinModules`/`flakeModules` and never
    # used that name, and nix warns about unknown outputs, so consumers import
    # `homeModules.default` (the nixvim-style convention).

    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in rec {
      # The engine (bin/android-settings) + the hook pack (hooks/) + the
      # settings library (props/) + shared helpers (lib/). Shebangs must be
      # native Termux
      # paths (/data/data/com.termux/files/usr/bin/sh) because the engine is
      # run natively from Termux AND inside the chroot (activation) — so no
      # fixup/patchShebangs on this derivation.
      android-settings = pkgs.runCommand "android-settings" {
        dontFixup = true;
      } ''
        mkdir -p $out/bin $out/share/android-settings
        cp ${self}/bin/android-settings $out/bin/android-settings
        cp -r ${self}/hooks $out/share/android-settings/hooks
        cp -r ${self}/props $out/share/android-settings/props
        cp -r ${self}/lib $out/share/android-settings/lib
        chmod +x $out/bin/android-settings $out/share/android-settings/hooks/*/run
      '';
      default = android-settings;
    });

    # `nix flake check` runs all three. They are deliberately device-free: the
    # test suite fakes su/settings/dumpsys (see tests/run.sh), so a check can
    # never touch the phone it runs on.
    checks = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      render = renderFor pkgs;

      # A configuration that exercises every rendering rule: float, bool, int,
      # list, the `cmd:` key, and an env value that needs shell quoting.
      propsFixture = {
        "global.window_animation_scale" = 0.75;
        "secure.night_display_enabled" = true;
        "qs.add" = ["flashlight" "screenrecord"];
        "cmd:" = ["svc wifi enable"];
      };
      hookConfigFixture = {
        "net-watch" = {
          CHECK_INTERVAL = 60;
          PROBE_TARGET = "1.1.1.1";
          ACTION = "cmd uimode night yes";
          LOG_PAUSE = false;
        };
      };

      expectedManifest = pkgs.writeText "expected.props" ''
        cmd:svc wifi enable
        global.window_animation_scale = 0.75
        qs.add = flashlight,screenrecord
        secure.night_display_enabled = 1
      '';
      actualManifest = pkgs.writeText "actual.props" (render.manifestText propsFixture);

      expectedEnv = pkgs.writeText "expected.env" ''
        ACTION='cmd uimode night yes'
        CHECK_INTERVAL=60
        LOG_PAUSE=0
        PROBE_TARGET=1.1.1.1
      '';
      actualEnv = pkgs.writeText "actual.env" (render.hookEnvTexts hookConfigFixture)."net-watch";

      expectedNames = pkgs.writeText "expected.names" "battery-low net-watch";
      actualNames = pkgs.writeText "actual.names" (render.hookNames ["battery-low" "net-watch"]);
      actualNamesEmpty = pkgs.writeText "actual.names.empty" (render.hookNames []);
    in {
      # Shell correctness, for both interpreters the code has to run under:
      # `sh` is dash on Termux (and ash inside the chroot), key-remap is bash.
      shell = pkgs.runCommand "android-settings-shell-check" {
        nativeBuildInputs = [pkgs.shellcheck pkgs.dash pkgs.bash pkgs.findutils pkgs.gnugrep];
      } ''
        export HOME=$TMPDIR
        cd ${self}

        sh_files="bin/android-settings $(ls lib/*.sh) $(ls hooks/*/run | grep -v key-remap)"
        # shellcheck disable=SC2086 — the list is meant to word-split.
        shellcheck --severity=warning -s sh $sh_files
        for f in $sh_files; do
          dash -n "$f"
          bash -n "$f"
        done

        # key-remap is the one bash hook (read -ra, <<<).
        shellcheck --severity=warning -s bash hooks/key-remap/run
        bash -n hooks/key-remap/run

        touch $out
      '';

      # The offline suite: manifest lint, apply/verify against a fake settings
      # DB, hook install/sync/remove, two hooks driven by fake dumpsys/getevent
      # fixtures, and lib/hook.sh unit assertions.
      tests = pkgs.runCommand "android-settings-tests" {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gnused
          pkgs.gawk
          pkgs.diffutils
        ];
      } ''
        export HOME=$TMPDIR/home
        mkdir -p "$HOME"
        sh ${self}/tests/run.sh
        touch $out
      '';

      # Golden files for modules/render.nix: the module is the only place where
      # a float, a bool or a value with spaces is turned into text, and getting
      # it wrong is silent (Android stores whatever string it is handed).
      render = pkgs.runCommand "android-settings-render-check" {
        nativeBuildInputs = [pkgs.diffutils];
      } ''
        set -eu
        fail() {
          echo "render check failed: $1" >&2
          exit 1
        }
        diff -u ${expectedManifest} ${actualManifest} || fail "manifest rendering changed"
        diff -u ${expectedEnv} ${actualEnv} || fail "hook env rendering changed"
        diff -u ${expectedNames} ${actualNames} || fail "hook name list rendering changed"
        test "$(cat ${actualNamesEmpty})" = "" || fail "an empty hook list must render as an empty string"
        touch $out
      '';
    });

    formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
  };
}
