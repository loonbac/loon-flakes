{
  description = "Configuración modular multi-host de NixOS — loon-flakes";

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
    # Antigravity CLI (`agy`) — no está en nixpkgs; flake que empaqueta
    # la app y el CLI de Google Antigravity, actualizado 3x/semana por su CI.
    antigravity-nix = {
      url = "github:jacopone/antigravity-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Steam con soporte para temas y plugins mediante Millennium.
    millennium.url = "github:SteamClientHomebrew/Millennium?dir=packages/nix";
    # SpaceTheme Fix para Millennium. No es un flake: se fija como fuente
    # inmutable en flake.lock y el modulo de Steam desempaqueta su release.
    space-theme-fix = {
      url = "github:Apollo-Nebula/SpaceTheme-Fix";
      flake = false;
    };
    # Herramientas para Steam: Accela, SLSsteam y utilidades (nix-tools-steam).
    nix-tools-steam = {
      url = "github:HANDZCZ/nix-tools-steam";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Gestión declarativa de aplicaciones Flatpak (juegos de nixos-pc).
    nix-flatpak.url = "github:gmodena/nix-flatpak/v0.7.0";
  };

  outputs = { self, nixpkgs, zen-browser, code-insiders-flake, antigravity-nix, millennium, space-theme-fix, nix-tools-steam, nix-flatpak }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};
      pkgsUnfree = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      # Gentle-AI stack: all versions and dependency hashes live under pkgs/.
      # The Pi package receives the same pinned Gentle-AI binary so both sides
      # use one RDD implementation and cannot drift silently.
      gentleAi = pkgs.callPackage ./pkgs/gentle-ai { };
      engram = pkgs.callPackage ./pkgs/engram { };
      piStack = pkgs.callPackage ./pkgs/pi { inherit gentleAi; };
      gentleAiBootstrap = pkgs.callPackage ./pkgs/gentle-ai-bootstrap {
        inherit gentleAi engram piStack;
      };

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

      # Accela parcheado con App ID explícito para Wayland/Niri (evita que reporte "python3").
      accela = nix-tools-steam.packages.${system}.accela.overrideAttrs (oldAttrs: {
        postPatch = (oldAttrs.postPatch or "") + ''
          substituteInPlace bin/src/main.py \
            --replace-fail 'app = QApplication(sys.argv)' $'app = QApplication(sys.argv)\n    app.setDesktopFileName("accela")'
        '';
      });

      steamidraPackage = pkgs.callPackage ./pkgs/steamidra { };
      steamidraOverlay = final: _prev: {
        steamidra = final.callPackage ./pkgs/steamidra { };
      };
      steamidraModule = ./modules/programs/steamidra;

      # "compilación final": como `cargo build` junta todos los crates,
      # aquí juntamos hosts + módulos en una configuración completa.
      # `specialArgs` pasa paquetes de otros flakes (zen-browser) a los módulos.
      mkHost = hostName: hostModules: lib.nixosSystem {
        inherit system;
        specialArgs = {
          zen-browser = zen-browser.packages.${system}.default;
          vscode-insiders = vscode-insiders;
          antigravity-cli = antigravity-nix.packages.${system}.google-antigravity-cli;
          inherit millennium space-theme-fix nix-tools-steam accela;
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
        niri-cycle = pkgs.callPackage ./pkgs/niri-cycle { };
        accent-wallpaper = pkgs.callPackage ./pkgs/accent-wallpaper { };
        mpvpaper-wallpaper = pkgs.callPackage ./pkgs/mpvpaper-wallpaper {
          accent-wallpaper = pkgs.callPackage ./pkgs/accent-wallpaper { };
        };
        # Tema de cursor Vision (blanco/negro) — paquetes propios del flake.
        vision-cursor = (pkgs.callPackage ./pkgs/vision-cursor { }).white;
        # Tema de cursor Win11OSX (Xcursor nativo de Linux).
        win11osx-cursor = pkgs.callPackage ./pkgs/win11osx-cursor { };
        vscode-insiders = vscode-insiders;
        zen-browser = zen-browser.packages.${system}.default;
        nixos-updates = pkgs.callPackage ./pkgs/nixos-updates { };
        nixos-ssh = pkgs.callPackage ./pkgs/nixos-ssh { };
        # Notificador de batería baja crítica (<=10%)
        battery-notify = pkgs.callPackage ./pkgs/battery-notify { };
        # Lanza apps de Android (Waydroid) levantando contenedor+sesión bajo demanda.
        waydroid-app = pkgs.callPackage ./pkgs/waydroid-app { };
        # Control de brillo con suelo mínimo del 10% remapeado a 0%
        screen-brightness = pkgs.callPackage ./pkgs/screen-brightness { };
        gentle-ai = gentleAi;
        engram = engram;
        gga = pkgs.callPackage ./pkgs/gga { };
        pi = piStack;
        gentle-ai-bootstrap = gentleAiBootstrap;
        cisco-packet-tracer = pkgsUnfree.callPackage ./pkgs/cisco-packet-tracer { };
        accela = accela;
        sls-steam = nix-tools-steam.packages.${system}.sls-steam;
        # SteaMidra (SFF): GUI de setup/manifest de Steam. AppImage oficial
        # envuelto en FHS para correr en NixOS (ver pkgs/steamidra).
        steamidra = steamidraPackage;
      };

      overlays = {
        steamidra = steamidraOverlay;
        default = steamidraOverlay;
      };

      nixosModules = {
        steamidra = steamidraModule;
        default = steamidraModule;
      };

      nixosConfigurations = {
        "loon-laptop" = mkHost "loon-laptop" [ ];
        "nixos-pc" = mkHost "nixos-pc" [ nix-flatpak.nixosModules.nix-flatpak ];
        "korosoft" = mkHost "korosoft" [ ];
      };
    };
}
