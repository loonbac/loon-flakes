{ pkgs, ... }:

let
  bridge = pkgs.callPackage ../../../pkgs/pi-ssh-clipboard { };
in
{
  environment.systemPackages = [ bridge ];

  # OpenSSH reenvía un socket Unix privado, no un puerto TCP: el shim
  # xclip-compatible de Pi solo puede leer una imagen mientras esa conexión
  # SSH exacta vive. El bloque que declaraba eso por host se retiró el
  # 2026-11-13 con sus hosts (loon-laptop y nixos-pc dejaron de existir): no
  # queda ningún peer al que reenviar el socket, y su lista `Host` guardaba
  # IPs LAN/Tailscale y alias en el repo público. Si vuelve a haber una
  # segunda máquina, re-declarar aquí `programs.ssh.extraConfig` con su
  # `Host <alias>` y el RemoteForward al socket de Pi.

  services.openssh.settings = {
    AllowStreamLocalForwarding = "yes";
    StreamLocalBindMask = "0177";
    StreamLocalBindUnlink = true;
  };

  systemd.user.services.pi-ssh-clipboard = {
    description = "Portapapeles de imágenes para Pi sobre SSH";
    wantedBy = [ "loon-niri-session.target" ];
    after = [ "niri.service" ];
    partOf = [ "loon-niri-session.target" ];
    serviceConfig = {
      ExecStart = "${bridge}/bin/pi-ssh-clipboard-server --socket %t/pi-clipboard-source.sock";
      Restart = "on-failure";
      RestartSec = "1s";
      RuntimeDirectory = "pi-ssh-clipboard";
      RuntimeDirectoryMode = "0700";
    };
  };
}
