# Cloudflare Tunnel (Zero Trust) con token, administrado desde el panel.
#
# Por qué no `services.cloudflared` de nixpkgs: ese módulo declara túneles con
# `credentialsFile` e `ingress` dentro del repo. Este es un túnel con token, cuyo
# ingress y rutas se administran en el panel de Cloudflare, así que basta el
# `--token-file`.
#
# El token NO vive aquí: es una credencial con control del túnel y este repo es
# público. Vive en `/var/lib/cloudflared/token` (0400 root). El directorio sí se
# declara con tmpfiles; el archivo nunca, porque su contenido acabaría en el
# store (de solo lectura y público).
#
# Aprovisionar el token en una máquina nueva (sin dejarlo en el historial del
# shell ni en el journal, que registra las líneas de sudo):
#   sudo install -d -m 0700 -o root -g root /var/lib/cloudflared
#   read -rsp "token: " T && printf '%s' "$T" | sudo tee /var/lib/cloudflared/token >/dev/null
#   unset T && sudo chmod 0400 /var/lib/cloudflared/token
#
# El binario se referencia desde la unidad, así que no se declara además en
# `systemPackages` (un paquete, un dueño). Para depurar en la línea de comandos:
# `nix shell nixpkgs#cloudflared`.
{ pkgs, ... }:

{
  systemd.tmpfiles.rules = [
    "d /var/lib/cloudflared 0700 root root -"
  ];

  systemd.services.cloudflared-tunnel = {
    description = "Cloudflare Tunnel (Zero Trust)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.cloudflared}/bin/cloudflared tunnel run --token-file /var/lib/cloudflared/token";
      Restart = "always";
      RestartSec = "5s";
    };
  };
}
