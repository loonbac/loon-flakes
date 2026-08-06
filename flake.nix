{
  description = "Configuración modular de NixOS para loon-laptop — loon-flakes";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Zen Browser (no está en nixpkgs; flake oficial de la wiki de NixOS).
    zen-browser = {
      url = "github:youwen5/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, zen-browser }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};

      # "compilación final": como `cargo build` junta todos los crates,
      # aquí juntamos hosts + módulos en una configuración completa.
      # `specialArgs` pasa paquetes de otros flakes (zen-browser) a los módulos.
      mkHost = hostName: hostModules: lib.nixosSystem {
        inherit system;
        specialArgs = {
          zen-browser = zen-browser.packages.${system}.default;
        };
        modules = [
          ./hosts/${hostName}
          ./modules
        ] ++ hostModules;
      };
    in
    {
      # Paquetes custom del flake (el "workspace" de binarios propios).
      packages.${system} = {
        rebuild = pkgs.callPackage ./pkgs/rebuild { };
        loon-launch = pkgs.callPackage ./pkgs/loon-launch { };
        zen-browser = zen-browser.packages.${system}.default;
      };

      nixosConfigurations = {
        "loon-laptop" = mkHost "loon-laptop" [ ];
      };
    };
}
