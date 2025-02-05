{
  pkgs ? import <nixpkgs> { },
  system ? builtins.currentSystem,
}:

let
  zig =
    let
      version = "master-2025-02-05";
    in
    (import (pkgs.fetchFromGitHub {
      owner = "mitchellh";
      repo = "zig-overlay";
      rev = "4dfa3d690edb7ae4cb332229b68dcf1ef30a1a03";
      sha256 = "sha256-pIWjN75ZMDQmj77GiT8yV3U3pFpQsv9An+xnK+UxhMI=";
    }) { inherit pkgs system; })."${version}";

  zls =
    let
      # Please find a matching ZLS version on https://zigtools.org/zls/install/
      # whenever the above Zig version is changed.
      version = "0.14.0-dev.366+d3d11a0";
      systems = {
        x86_64-linux = "sha256-yv0mi8XMdVQTcxE96Z/bpsaXW76G8A8Rrd8GKLw1P64=";
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
