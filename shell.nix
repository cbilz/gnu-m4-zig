{
  pkgs ? import <nixpkgs> { },
  system ? builtins.currentSystem,
}:

let
  zig =
    let
      version = "master-2025-01-30";
    in
    (import (pkgs.fetchFromGitHub {
      owner = "mitchellh";
      repo = "zig-overlay";
      rev = "1a8fb6f3a04724519436355564b95fce5e272504";
      sha256 = "Y5i9mQ++dyIQr+zEPNy+KIbc5wjPmfllBrag3cHZgcE=";
    }) { inherit pkgs system; })."${version}";

  zls =
    let
      # Please find a matching ZLS version on https://zigtools.org/zls/install/
      # whenever the above Zig version is changed.
      version = "0.14.0-dev.365+6a16b27";
      systems = {
        x86_64-linux = "YOQVW+DdH7Dpv57KluLj6SWbJ7gFHW2qGT1hi+UCMag=";
      };
      sha256 = systems.${system};
      splits = pkgs.lib.strings.splitString "-" system;
      arch = builtins.elemAt splits 0;
      os = builtins.elemAt splits 1;
    in
    pkgs.stdenv.mkDerivation {
      pname = "zls";
      inherit version;
      src = pkgs.fetchurl {
        url = "https://builds.zigtools.org/zls-${os}-${arch}-${version}.tar.xz";
        inherit sha256;
      };
      sourceRoot = ".";
      dontConfigure = true;
      dontBuild = true;
      dontFixup = true;
      installPhase = ''
        mkdir -p $out/bin
        cp zls $out/bin/zls
      '';
    };
in
pkgs.mkShell {
  packages = [
    zig
    zls
  ];
}
