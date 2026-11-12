# Host de ejemplo: plantilla para una máquina nueva (leer antes de copiar).
#
# 1. Copia este directorio a `hosts/<tu-host>/` (p. ej. `hosts/mi-pc/`).
# 2. Genera el hardware real y sustituye el import de abajo:
#      nixos-generate-config --show-hardware-config > hosts/<tu-host>/hardware-configuration.nix
# 3. Declara el host en `flake.nix` (`nixosConfigurations`), como indica el
#    comentario de ejemplo que hay allí.
# 4. Ajusta `loon.*` abajo: quién eres y qué áreas personales copias (con TUS
#    claves en TU home, nunca las de otro). Todo lo que no enciendas
#    explícitamente queda apagado y nada de nadie se instala en tu máquina.
{
  imports = [
    # Lo genera nixos-generate-config en la máquina real. Este archivo no se
    # versiona con contenido ajeno: cada host tiene el suyo.
    ./hardware-configuration.nix
  ];

  networking.hostName = "ejemplo";

  # Quién eres. Sin esto la evaluación falla a propósito (ver
  # `loon.knownHosts` en `modules/loon/default.nix`): es mejor un error claro
  # ahora que el usuario de otro instalado en silencio.
  loon.username = "tu-usuario";
  loon.fullName = "Tu Nombre";

  # Catálogo personal de loonbac, todo apagado por defecto para un host nuevo.
  # Enciende solo lo que copies con tus propios archivos:
  loon.personal.enable = false;
  # loon.personal.piProviders = true;  # + TUS claves en ~/.config/*/api-key (0600)
  # loon.personal.judges = true;       # + TUS logins de Antigravity
  # loon.personal.mcpServers = true;   # + TUS repos/wrappers en tu home

  # Puertos TCP de tus servidores de desarrollo (ejemplo).
  loon.devPorts = [ 5173 8080 ];

  system.stateVersion = "26.05";
}
