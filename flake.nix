{
  description = "The Snail Shell 🐌";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-24.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-compat.follows = "";
      };
    };
  };

  outputs = {self, nixpkgs, nixpkgs-unstable, zig, ...}:
    builtins.foldl' nixpkgs.lib.recursiveUpdate {} (builtins.map (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      pkgs-unstable = nixpkgs-unstable.legacyPackages.${system};
    in {
      devShells.${system} = pkgs.mkShell {
        name = "snail";
        packages =
          [
            zig.packages.${system}."0.13.0"
          ];
      };
      packages.${system} = let
          mkArgs = optimize: {
            inherit (pkgs-unstable) zig_0_13 stdenv;
            inherit optimize;

            revision = self.shortRev or self.dirtyShortRev or "dirty";
          };
      in rec {
        snail-debug = pkgs.callPackage ./nix/package.nix (mkArgs "Debug");
        snail-fast = pkgs.callPackage ./nix/package.nix (mkArgs "ReleaseFast");
        snail = pkgs.callPackage ./nix/package.nix (mkArgs "ReleaseSafe");
        default = snail;
      };

    }
    ) (builtins.attrNames zig.packages));
}
