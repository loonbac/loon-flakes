# Servidor de streaming exclusivo de nixos-pc para clientes Moonlight.
{ ... }:

{
  services.moonshine = {
    enable = true;
    user = "loonbac";
    uid = 1000;

    # Escucha en todas las interfaces IPv4 e IPv6 y abre los puertos de
    # GameStream en el firewall de NixOS.
    openFirewall = true;
    settings = {
      name = "nixos-pc";
      address = "::";
      application = [
        {
          title = "Steam";
          command = [
            "/run/current-system/sw/bin/steam"
            "steam://open/bigpicture"
          ];
        }
      ];
      application_scanner = [
        {
          type = "steam";
          library = "$HOME/.local/share/Steam";
          command = [
            "/run/current-system/sw/bin/steam"
            "-bigpicture"
            "steam://rungameid/{game_id}"
          ];
        }
      ];
    };
  };

  # Permite gamepads en sesiones headless y evita la suspensión mientras se
  # transmite. Estas membresías se suman a los grupos comunes del usuario.
  users.users.loonbac.extraGroups = [
    "input"
    "moonshine"
  ];
}
