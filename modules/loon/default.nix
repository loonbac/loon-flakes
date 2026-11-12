# Módulo "loon": identidad y catálogo personal de este flake.
#
# Todo lo que es *de una persona concreta* (nombre de usuario, claves de API,
# servidores MCP de su home, providers de Pi con sus credenciales) cuelga de
# estas opciones. Los defaults reproducen la máquina de loonbac tal cual está
# hoy: un `git pull` no cambia nada en los hosts existentes.
#
# Un clonador solo toca lo suyo: `loon.username` (+ sus archivos de claves en
# su propio home) y apaga con `false` cada área personal que no quiera. Nada
# exige borrar ni comentar código ajeno; ver `hosts/ejemplo/default.nix`.
{ config, lib, ... }:

{
  options.loon.username = lib.mkOption {
    type = lib.types.str;
    default = "loonbac";
    example = "amigo";
    description = ''
      Usuario principal del sistema. Se crea en users.users, es dueño del
      home y ejecuta el servicio gentle-ai-bootstrap.
    '';
  };

  options.loon.home = lib.mkOption {
    type = lib.types.str;
    default = "/home/${config.loon.username}";
    example = "/home/amigo";
    description = ''
      Home del usuario principal. Por defecto deriva del username; solo
      hace falta fijarlo si el home no sigue la convención /home/<usuario>.
    '';
  };

  options.loon.knownHosts = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ "loon-laptop" "nixos-pc" ];
    example = [ "loon-laptop" "nixos-pc" "mi-pc" ];
    description = ''
      Hosts que pertenecen a loonbac y conservan su identidad y su catálogo
      personal. Un host fuera de esta lista con el username por defecto es
      casi seguro un fork sin personalizar: la aserción de abajo lo detiene
      con un mensaje claro en vez de instalar silenciosamente el usuario y
      los providers de otro. Si de verdad eres loonbac en una máquina nueva,
      añade su hostname aquí.
    '';
  };

  options.loon.fullName = lib.mkOption {
    type = lib.types.str;
    default = "Joshua Rosales";
    example = "Nombre Apellido";
    description = ''
      Nombre descriptivo del usuario principal (login managers, etc.).
    '';
  };

  options.loon.personal.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Interruptor general del catálogo personal de loonbac: providers de Pi
      con sus credenciales, perfiles de jueces, servidores MCP de su home y
      ajustes propios. Apagarlo deja un sistema funcional sin datos de
      nadie; cada área se puede encender por separado abajo.
    '';
  };

  options.loon.personal.piProviders = lib.mkOption {
    type = lib.types.bool;
    default = config.loon.personal.enable;
    description = ''
      Providers de Pi de loonbac (mistral-vibe, inception): su estructura,
      costes y mapas de thinking. Las claves las pone cada uno en su propio
      home (~/.config/<nombre>/api-key, 0600); sin el archivo la entrada no
      autentica, pero tampoco rompe al resto.
    '';
  };

  options.loon.personal.judges = lib.mkOption {
    type = lib.types.bool;
    default = config.loon.personal.enable;
    description = ''
      Perfiles de jueces (jd-judge-a/b) y fallbacks atados a las cuentas de
      loonbac. Requieren sus logins; apagados no afectan al resto del stack.
    '';
  };

  options.loon.personal.mcpServers = lib.mkOption {
    type = lib.types.bool;
    default = config.loon.personal.enable;
    description = ''
      Servidores MCP del home de loonbac (rakya, flow-mcp, dataimpulse,
      voice-gen): wrappers y datos mutables que solo existen en su máquina.
    '';
  };

  config.assertions = [
    {
      assertion =
        builtins.elem config.networking.hostName config.loon.knownHosts
        || config.loon.username != "loonbac";
      message = ''
        Este host (${config.networking.hostName}) no está en loon.knownHosts y
        usa el usuario por defecto (loonbac). Si es tu máquina, personaliza
        hosts/${config.networking.hostName}/default.nix: pon `loon.username =
        "tu-usuario";` (y `loon.personal.enable = false;` salvo las áreas que
        copies con tus propias claves). Ver README «Clonar este flake para tu
        propia máquina» y la plantilla en hosts/ejemplo/.
      '';
    }
  ];
}
