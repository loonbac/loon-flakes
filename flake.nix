{
  description = "Configuración modular de NixOS para loon-laptop — loon-flakes";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Zen Browser (no está en nixpkgs; flake oficial de la wiki de NixOS).
    zen-browser = {
      url = "github:youwen5/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # VS Code Insiders (no está en nixpkgs; flake que lo empaqueta al día).
    code-insiders-flake = {
      url = "github:iosmanthus/code-insiders-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, zen-browser, code-insiders-flake }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};

      # VS Code Insiders: el flake upstream solo provee el meta.json
      # (version + sha256 + url del tarball actualizado a diario por su CI).
      # En Linux, nixpkgs parchea el ripgrep del tarball (rm + ln o chmod),
      # pero Insiders no lo trae en esa ruta y el patchPhase falla.
      # Insiders ya incluye su propio ripgrep funcional, así que lo anulamos.
      vscode-insiders = let
        meta = builtins.fromJSON (
          builtins.readFile "${code-insiders-flake}/meta.json"
        );
      in
        (pkgs.vscode.override {
          isInsiders = true;
          useVSCodeRipgrep = true;
        }).overrideAttrs
          (oldAttrs: {
            pname = "vscode-insiders";
            src = builtins.fetchurl {
              url = meta.url;
              sha256 = meta.sha256;
            };
            version = meta.version;
            meta.mainProgram = "code-insiders";
            # Anular fases de nixpkgs que asumen una estructura que Insiders
            # no trae: el patchPhase (ripgrep) y el postFixup (vsce-sign)
            # fallan porque esos binarios no existen en el tarball de Insiders.
            patchPhase = "true";
            postFixup = "true";
          });

      # "compilación final": como `cargo build` junta todos los crates,
      # aquí juntamos hosts + módulos en una configuración completa.
      # `specialArgs` pasa paquetes de otros flakes (zen-browser) a los módulos.
      mkHost = hostName: hostModules: lib.nixosSystem {
        inherit system;
        specialArgs = {
          zen-browser = zen-browser.packages.${system}.default;
          vscode-insiders = vscode-insiders;
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
        loon-bar = pkgs.callPackage ./pkgs/loon-bar { };
        niri-cycle = pkgs.callPackage ./pkgs/niri-cycle { };
        # Shake-to-find cursor (estilo macOS) para niri.
        niri-shake-cursor = pkgs.callPackage ./pkgs/niri-shake-cursor { };
        # Tema de cursor Vision (blanco/negro) — paquetes propios del flake.
        vision-cursor = pkgs.callPackage ./pkgs/vision-cursor { };
        # Tema de cursor Win11OSX (Xcursor nativo de Linux).
        win11osx-cursor = pkgs.callPackage ./pkgs/win11osx-cursor { };
        vscode-insiders = vscode-insiders;
        zen-browser = zen-browser.packages.${system}.default;
      };

      nixosConfigurations = {
        "loon-laptop" = mkHost "loon-laptop" [ ];
      };
    };
}
