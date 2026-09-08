# Steam moddeable mediante Millennium, con soporte para SLSsteam (inyección 32-bit)
# y Accela (gestor/downloader integrado con LuaTools).
{ config, lib, pkgs, millennium, nix-tools-steam ? null, accela ? null, ... }:

let
  cfg = config.loon.programs.steam;
  steamTools =
    if nix-tools-steam != null && nix-tools-steam ? packages && nix-tools-steam.packages ? ${pkgs.stdenv.hostPlatform.system}
    then nix-tools-steam.packages.${pkgs.stdenv.hostPlatform.system}
    else null;
  slsSteam = if steamTools != null then steamTools.sls-steam else null;
  accelaPkg =
    if accela != null then
      accela
    else if steamTools != null then
      steamTools.accela
    else
      null;
in
{
  imports = [
    ./space-theme-fix.nix
  ];

  options.loon.programs.steam = {
    enable = lib.mkEnableOption
      "Steam con el framework de temas y plugins Millennium";

    slssteam = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Inyectar librerías 32-bit de SLSsteam vía LD_AUDIT en Steam";
      };
    };

    accela = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Habilitar Accela (empaquetado nativo para NixOS) y enlazarlo para LuaTools";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.overlays = [ millennium.overlays.default ];

    programs.steam = {
      enable = true;
      package =
        if cfg.slssteam.enable && slsSteam != null then
          pkgs.millennium-steam.override (orig: {
            extraLibraries = pkgs: [ slsSteam ] ++ ((orig.extraLibraries or (_: [ ])) pkgs);
            extraEnv = (orig.extraEnv or { }) // {
              LD_AUDIT = slsSteam.passthru.LD_AUDIT;
            };
          })
        else
          pkgs.millennium-steam;
    };

    environment.systemPackages = lib.optionals (cfg.accela.enable && accelaPkg != null) [
      accelaPkg
    ];

    # Directorios, symlinks y archivos de configuración para que LuaTools y los launchers
    # encuentren Accela y SLSsteam sin configuración manual adicional.
    systemd.tmpfiles.rules =
      (lib.optionals (cfg.accela.enable && accelaPkg != null) [
        "d /home/loonbac/.local/share/ACCELA 0755 loonbac users -"
        "L+ /home/loonbac/.local/share/ACCELA/run.sh - - - - ${pkgs.writeShellScript "accela-run" ''exec ${lib.getExe accelaPkg} "$@"''}"
        "d \"/home/loonbac/.config/Tachibana Labs\" 0755 loonbac users -"
        "C \"/home/loonbac/.config/Tachibana Labs/ACCELA.conf\" - - - - /etc/accela/default.conf"
      ])
      ++ (lib.optionals (cfg.slssteam.enable && slsSteam != null) [
        "d /home/loonbac/.local/share/SLSsteam 0755 loonbac users -"
        "L+ /home/loonbac/.local/share/SLSsteam/SLSsteam.so - - - - ${slsSteam}/lib/SLSsteam.so"
        "L+ /home/loonbac/.local/share/SLSsteam/library-inject.so - - - - ${slsSteam}/lib/library-inject.so"
        "d /home/loonbac/.config/SLSsteam 0755 loonbac users -"
        "C /home/loonbac/.config/SLSsteam/config.yaml - - - - /etc/SLSsteam/default-config.yaml"
      ]);

    environment.etc = lib.mkMerge [
      (lib.mkIf (cfg.slssteam.enable && slsSteam != null) {
        "SLSsteam/default-config.yaml".text = ''
          DisableFamilyShareLock: yes
          UseWhitelist: no
          AppIds:
          AdditionalApps:
          DlcData:
          AppTokens:
          CDKeys:
          FakeOffline:
          FakeAppIds:
          ManifestIds:
          DepotBlacklist:
          IdleStatus:
            AppId: 0
            Title: ""
          GameTitles:
          SubscriptionTimestamps:
          DenuvoGames:
          SteamIdOverride:
          SmartTickets: 0x1
          MaxSchemaTries: 10
          LaunchOptions:
          SafeMode: no
          WarnHashMissmatch: no
          NotifyInit: yes
          API: no
          Plugins: no
          DisableCloud: yes
          DisableUpdates: yes
          FakeName: ""
          FakeEmail: ""
          FakeWalletBalance: 0
          LogLevels: 0xff
          DumpClientInterfaces: no
          ExtendedLogging: no
        '';
      })
      (lib.mkIf (cfg.accela.enable && accelaPkg != null) {
        "accela/default.conf".text = ''
          [General]
          auto_skip_single_choice=true
          library_mode=true
          max_downloads=16
          sls_config_management=true
          slssteam_mode=true
          use_steamless=true
        '';
      })
    ];
  };
}
