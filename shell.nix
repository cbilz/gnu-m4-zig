{
  pkgs ? import <nixpkgs> { },
  system ? builtins.currentSystem,
}:

let
  zig =
    let
      version = "master-2025-02-25";
    in
    (import (pkgs.fetchFromGitHub {
      owner = "mitchellh";
      repo = "zig-overlay";
      rev = "289cc07b8e416d16a6f8117a6ede45e001b35b1d";
      sha256 = "sha256-mztnIaWt7EPsklSQz3A3wlWUIHbhH6qnGzyrGUTrB8Y=";
    }) { inherit pkgs system; })."${version}";

  zls =
    let
      # Please find a matching ZLS version on https://zigtools.org/zls/install/
      # whenever the above Zig version is changed.
      version = "0.14.0-dev.397+30b0da0";
      systems = {
        x86_64-linux = "sha256-l2Cz6ttxmnCF9OUZsF5Jg5uvcVd9q9/xY2OEJh/RSZQ=";
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
pkgs.mkShellNoCC {
  packages = [
    zig
    zls
    pkgs.lldb
  ];
}
