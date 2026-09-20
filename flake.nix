{
  description =
    "aliyss-android-settings — declarative Android settings + hook services for the aliyss phone (engine lives in this repo, home-manager consumes it)";

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
  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in rec {
      # The engine (bin/android-settings) + the hook pack (hooks/) + the
      # reference props manifest (props/). Shebangs must stay native Termux
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
        chmod +x $out/bin/android-settings $out/share/android-settings/hooks/*/run
      '';
      default = android-settings;
    });

    formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
  };
}
