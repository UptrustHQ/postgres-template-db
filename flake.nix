{
  description = "Development shell: GHC 9.10, cabal-install and PostgreSQL";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/7dcdd87373d72e7a2173e4db02e20d3d7f495cfd";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.haskell.compiler.ghc9103
            pkgs.cabal-install
            pkgs.pkg-config
            pkgs.postgresql_17
            pkgs.libpq.dev
            pkgs.zlib.dev
          ];
        };
      });
    };
}
