{
  description = "Configuración modular multi-host de NixOS — loon-flakes";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Citron Nextendo: empaqueta los AppImages Linux oficiales en URLs
    # inmutables y expone un módulo NixOS reutilizable; no recompila Citron.
    citron-nextendo = {
      url = "github:loonbac/citron-nextendo-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # PORT: terminal con GPUI y sistema de plugins. Repositorio local mientras
    # no haya release estable publicada.
    port = {
      url = "git+file:///home/loonbac/Proyectos/port";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Zen Browser (no está en nixpkgs; flake oficial de la wiki de NixOS).
    zen-browser = {
      url = "github:youwen5/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Helium Browser (no está en nixpkgs; navegador enfocado en privacidad basado en Chromium).
    helium-browser = {
      url = "github:schembriaiden/helium-browser-nix-flake";
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
    # LOON: LOON Offers Only Nuanced-gentle — identidad visual Claude Code para
    # pi. Vive en su propio repo para tener historia y cadence propios; aquí
    # queda fijado en flake.lock para que la build sea reproducible.
    loon = {
      url = "github:loonbac/loon";
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
    nix-flatpak.url = "github:gmodena/nix-flatpak";
    # Secure Boot para nixos-pc. Lanzaboote firma el cargador, kernel e initrd.
    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, citron-nextendo, port, zen-browser, code-insiders-flake, antigravity-nix, loon, millennium, space-theme-fix, nix-tools-steam, nix-flatpak, lanzaboote, helium-browser }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};
      pkgsUnfree = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      # Gentle-AI stack: Nix owns stable launchers and configuration; the
      # user-writable Pi installation owns its own updates and gentle-pi's
      # verified, version-matched Gentle AI runtime.
      piLauncher = pkgs.callPackage ./pkgs/pi-launcher { };
      gentleAiLauncher = pkgs.callPackage ./pkgs/gentle-ai-launcher { };
      gentleAiRuntimeUpdater = pkgs.callPackage ./pkgs/gentle-ai-runtime-updater { };
      engramUpdater = pkgs.callPackage ./pkgs/engram-updater { };
      engramLauncher = pkgs.callPackage ./pkgs/engram-launcher {
        inherit engramUpdater;
      };
      betterClaudeCodeUi = loon.packages.${system}.default;
      gptFastModeShared = pkgs.callPackage ./pkgs/pi/gpt-fast-mode-shared { };
      gentleAiBootstrap = pkgs.callPackage ./pkgs/gentle-ai-bootstrap {
        inherit
          piLauncher
          gentleAiLauncher
          gentleAiRuntimeUpdater
          engramLauncher
          betterClaudeCodeUi
          gptFastModeShared
          ;
      };
      gentleStackUpdate = pkgs.callPackage ./pkgs/gentle-stack-update {
        inherit piLauncher gentleAiLauncher gentleAiRuntimeUpdater engramLauncher;
        gentleAiBootstrap = gentleAiBootstrap;
      };
      piSshClipboard = pkgs.callPackage ./pkgs/pi-ssh-clipboard { };

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

      citronNextendoPackage = citron-nextendo.packages.${system}.default;
      citronNextendoOverlay = citron-nextendo.overlays.default;
      citronNextendoModule = citron-nextendo.nixosModules.default;

      veadotubeMiniPackage = pkgsUnfree.callPackage ./pkgs/veadotube-mini { };
      veadotubeMiniOverlay = final: _prev: {
        veadotube-mini = final.callPackage ./pkgs/veadotube-mini { };
      };
      veadotubeMiniModule = ./modules/programs/veadotube-mini;

      obsPwvideoPackage = pkgs.callPackage ./pkgs/obs-pwvideo { };
      obsPwvideoOverlay = final: _prev: {
        obs-pwvideo = final.callPackage ./pkgs/obs-pwvideo { };
      };
      obsPwvideoModule = ./modules/programs/obs-pwvideo;

      # "compilación final": como `cargo build` junta todos los crates,
      # aquí juntamos hosts + módulos en una configuración completa.
      # `specialArgs` pasa paquetes de otros flakes (zen-browser) a los módulos.
      mkHost = hostName: hostModules: lib.nixosSystem {
        inherit system;
        specialArgs = {
          zen-browser = zen-browser.packages.${system}.default;
          helium-browser = helium-browser.packages.${system}.default;
          vscode-insiders = vscode-insiders;
          antigravity-cli = antigravity-nix.packages.${system}.google-antigravity-cli;
          loon = betterClaudeCodeUi;
          inherit millennium space-theme-fix nix-tools-steam accela citron-nextendo;
          # PORT llega como paquete ya resuelto: el modulo no debe conocer
          # inputs del flake ni llamar a getFlake, que exigiria --impure.
          port = port.packages.${system}.default;
        };
        modules = [
          ./hosts/${hostName}
          ./modules
        ] ++ hostModules;
      };

      # `checks`: un check por host que solo *evalúa* su configuración.
      #
      # Forzamos el `drvPath` del toplevel del sistema, lo que evalúa la
      # configuración completa (módulos, tipos, aserciones y `imports`) y
      # volcamos el resultado en una derivación trivial. Así `nix flake check`
      # detecta errores de evaluación sin compilar dos sistemas NixOS.
      #
      # `unsafeDiscardStringContext` es deliberado: sin él la cadena del
      # `drvPath` arrastraría el contexto de derivación y el check heredaría
      # el toplevel como dependencia de build, de modo que `nix flake check`
      # terminaría construyendo los dos sistemas. Al descartarlo, el check
      # fuerza la evaluación igual, pero se construye en milisegundos.
      #
      # Ejecutar: `nix flake check --no-build` (evalúa ambos hosts sin
      # construir nada). Sin ese flag, `nix flake check` construye además los
      # toplevels de `nixosConfigurations` y los paquetes del flake, que es el
      # comportamiento propio de ese comando y no algo que introduzcan estos
      # checks.
      hostEvalCheck = hostName:
        pkgs.runCommand "eval-${hostName}" { } ''
          echo ${lib.escapeShellArg (builtins.unsafeDiscardStringContext
            self.nixosConfigurations.${hostName}.config.system.build.toplevel.drvPath)} > $out
        '';
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
        # Tema de cursor Win11OSX (Xcursor nativo de Linux).
        win11osx-cursor = pkgs.callPackage ./pkgs/win11osx-cursor { };
        vscode-insiders = vscode-insiders;
        zen-browser = zen-browser.packages.${system}.default;
        helium-browser = helium-browser.packages.${system}.default;
        nixos-updates = pkgs.callPackage ./pkgs/nixos-updates { };
        nixos-ssh = pkgs.callPackage ./pkgs/nixos-ssh { };
        # Notificador de batería baja crítica (<=10%)
        battery-notify = pkgs.callPackage ./pkgs/battery-notify { };
        # Lanza apps de Android (Waydroid) levantando contenedor+sesión bajo demanda.
        waydroid-app = pkgs.callPackage ./pkgs/waydroid-app { };
        # Control de brillo con suelo mínimo del 10% remapeado a 0%
        screen-brightness = pkgs.callPackage ./pkgs/screen-brightness { };
        gentle-ai = gentleAiLauncher;
        gentle-ai-runtime-update = gentleAiRuntimeUpdater;
        engram = engramLauncher;
        engram-update = engramUpdater;
        gga = pkgs.callPackage ./pkgs/gga { };
        pi = piLauncher;
        pi-ssh-clipboard = piSshClipboard;
        better-claude-code-ui = betterClaudeCodeUi;
        pi-gpt-fast-mode-shared = gptFastModeShared;
        gentle-ai-bootstrap = gentleAiBootstrap;
        gentle-stack-update = gentleStackUpdate;
        cisco-packet-tracer = pkgsUnfree.callPackage ./pkgs/cisco-packet-tracer { };
        accela = accela;
        sls-steam = nix-tools-steam.packages.${system}.sls-steam;
        # SteaMidra (SFF): GUI de setup/manifest de Steam. AppImage oficial
        # envuelto en FHS para correr en NixOS (ver pkgs/steamidra).
        steamidra = steamidraPackage;
        # Fork de Citron Neo con juego online mediante Nextendo Network.
        citron-nextendo = citronNextendoPackage;
        citron-nextendo-v3 = citron-nextendo.packages.${system}.citron-nextendo-v3;
        veadotube-mini = veadotubeMiniPackage;
        obs-pwvideo = obsPwvideoPackage;
        cli-proxy-api = pkgs.callPackage ./pkgs/cli-proxy-api { };
        cline = pkgs.callPackage ./pkgs/cline-launcher { };
      };

      overlays = {
        steamidra = steamidraOverlay;
        citron-nextendo = citronNextendoOverlay;
        veadotube-mini = veadotubeMiniOverlay;
        obs-pwvideo = obsPwvideoOverlay;
        default = lib.composeManyExtensions [
          steamidraOverlay
          citronNextendoOverlay
          veadotubeMiniOverlay
          obsPwvideoOverlay
        ];
      };

      nixosModules = {
        steamidra = steamidraModule;
        citron-nextendo = citronNextendoModule;
        veadotube-mini = veadotubeMiniModule;
        obs-pwvideo = obsPwvideoModule;
        default = steamidraModule;
      };

      nixosConfigurations = {
        "loon-laptop" = mkHost "loon-laptop" [ ];
        "nixos-pc" = mkHost "nixos-pc" [
          citron-nextendo.nixosModules.default
          nix-flatpak.nixosModules.nix-flatpak
          lanzaboote.nixosModules.lanzaboote
        ];
      };

      # Un check de evaluación por cada host declarado arriba (una sola
      # fuente para los nombres). Ver `hostEvalCheck` en el `let`.
      checks.${system} =
        lib.genAttrs (builtins.attrNames self.nixosConfigurations) hostEvalCheck;
    };
}
