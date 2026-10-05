# Módulo "services/docker": daemon de contenedores Docker.
# El daemon vive en /var/lib/docker; el grupo `docker` da acceso al socket sin sudo.
{ config, lib, pkgs, ... }:

{
  virtualisation.docker.enable = true;

  # Usuario con acceso al socket del daemon sin sudo (misma pauta que waydroid).
  users.users.loonbac.extraGroups = [ "docker" ];

  # Compose v2 para declarar stacks de contenedores.
  environment.systemPackages = with pkgs; [
    docker-compose
  ];
}
