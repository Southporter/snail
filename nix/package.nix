{
  lib,
  stdenv,
  optimize ? "Debug",
  zig_0_13,
  platforms,
  revision ? "dirty",
}: let
  zig_hook = zig_0_13.hook.overrideAttrs {
    zig_default_flags = "-Dcpu=baseline -Doptimize=${optimize}";
  };

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.intersection (lib.fileset.fromSource (lib.sources.cleanSource ../.)) (
      lib.fileset.unions [
        ../src
        ../build.zig
        ../build.zig.zon
      ]
    );
  };
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "snail";
    version = "0.0.1";
    inherit src;

    nativeBuildInputs = [ zig_hook ];

    dontConfigure = true;

    outputs = [ "out" ];

    meta = {
      platforms = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
      homepage = "https://github.com/Southporter/snail";
      mainProgram = "snail";
    };
  })
