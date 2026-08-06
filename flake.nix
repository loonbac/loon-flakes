{
  description = "Configuración modular de NixOS para korosoft — loon-flakes";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;

      # "compilación final": como `cargo build` junta todos los crates,
      # aquí juntamos hosts + módulos en una configuración completa.
      mkHost = hostName: hostModules: lib.nixosSystem {
        inherit system;
        modules = [
          ./hosts/${hostName}
          ./modules
        ] ++ hostModules;
      };
    in
    {
      nixosConfigurations = {
        korosoft = mkHost "korosoft" [ ];
      };
    };
}
