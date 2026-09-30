# Módulo "services/cli-proxy-api": servidor CLI Proxy API en segundo plano
# para exponer interfaces compatibles con OpenAI/Gemini/Claude a partir de
# modelos CLI (Antigravity, Codex, Claude Code, Grok, etc.).
{ config, lib, pkgs, ... }:

let
  cfg = config.services.cli-proxy-api;

  yamlFormat = pkgs.formats.yaml { };

  defaultSettings = {
    config-version = 8;
    server = {
      host = cfg.host;
      port = cfg.port;
    };
    management = {
      allow-remote = false;
      secret-key = cfg.managementKey;
      disable-control-panel = false;
    };
    oauth = {
      auth-dir = cfg.authDir;
    };
    plugins = {
      enabled = cfg.enablePlugins;
      dir = cfg.pluginsDir;
    };
    observability = {
      logs = {
        logging-to-file = true;
      };
    };
  };

  finalSettings = lib.recursiveUpdate defaultSettings cfg.settings;
  configFile = yamlFormat.generate "cli-proxy-api-config.yaml" finalSettings;
in
{
  options.services.cli-proxy-api = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Habilita el servidor CLI Proxy API como servicio de sistema.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../../pkgs/cli-proxy-api { };
      description = "Paquete de CLI Proxy API a utilizar.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Dirección IP o interfaz en la que escuchará el servidor.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 63817;
      description = "Puerto TCP en el que escuchará el servidor. Por defecto se usa el 63817 (rango privado, fuera del rango efímero local de Linux y sin colisiones).";
    };

    managementKey = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Clave secreta para acceder al panel de administración web (/management.html).";
    };

    enablePlugins = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Habilita la ejecución y soporte de plugins en CLI Proxy API.";
    };

    pluginsDir = lib.mkOption {
      type = lib.types.str;
      default = "/home/${cfg.user}/.cli-proxy-api/plugins";
      description = "Directorio donde se descargan e instalan los plugins de CLI Proxy API.";
    };

    authDir = lib.mkOption {
      type = lib.types.str;
      default = "/home/${cfg.user}/.cli-proxy-api";
      description = "Directorio donde se almacenan las credenciales y tokens OAuth.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "loonbac";
      description = "Usuario bajo el cual se ejecuta el servicio del sistema.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "users";
      description = "Grupo bajo el cual se ejecuta el servicio del sistema.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Abre el puerto configurado en el firewall de NixOS.";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Opciones adicionales para el archivo config.yaml de CLI Proxy API.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    environment.etc."cli-proxy-api/config.yaml".source = configFile;

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

    systemd.services.cli-proxy-api = {
      description = "CLI Proxy API Server";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      preStart = ''
        mkdir -p /home/${cfg.user}/.cli-proxy-api
        if [ ! -f /home/${cfg.user}/.cli-proxy-api/config.yaml ]; then
          cp ${configFile} /home/${cfg.user}/.cli-proxy-api/config.yaml
          chmod 600 /home/${cfg.user}/.cli-proxy-api/config.yaml
        fi
      '';
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = "/home/${cfg.user}";
        Environment = [
          "HOME=/home/${cfg.user}"
          "MANAGEMENT_STATIC_PATH=/home/${cfg.user}/.cli-proxy-api/static"
        ];
        ExecStart = "${cfg.package}/bin/cli-proxy-api -config /home/${cfg.user}/.cli-proxy-api/config.yaml";
        Restart = "always";
        RestartSec = "5s";
      };
    };
  };
}
