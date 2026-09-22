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

    formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
  };
}
