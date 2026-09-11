# Servicio Tailscale: red privada mesh entre dispositivos (VPN WireGuard).
# Tras el rebuild: `sudo tailscale up` para autenticar y unir la máquina a la tailnet.
{ config, lib, pkgs, ... }:

let
  isLoonLaptop = config.networking.hostName == "loon-laptop";
  stateDir = "/var/lib/ts-bypass";
  environmentFile = "${stateDir}/tailscaled.env";

  stateHelper = pkgs.writeShellScript "ts-bypass-state" ''
    set -euo pipefail

    state_dir=${lib.escapeShellArg stateDir}
    environment_file=${lib.escapeShellArg environmentFile}

    case "''${1:-}" in
      enable)
        ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root "$state_dir"
        umask 022
        ${pkgs.coreutils}/bin/printf '%s\n' \
          'ALL_PROXY=socks5://127.0.0.1:1080' > "$environment_file.new"
        ${pkgs.coreutils}/bin/mv -f "$environment_file.new" "$environment_file"
        ;;
      disable)
        ${pkgs.coreutils}/bin/rm -f "$environment_file" "$environment_file.new"
        ;;
      *)
        echo "Uso interno: ts-bypass-state {enable|disable}" >&2
        exit 2
        ;;
    esac
  '';

  tunnel = pkgs.writeShellScript "ts-bypass-tunnel" ''
    set -euo pipefail
    exec ${pkgs.openssh}/bin/ssh \
      -N \
      -D 127.0.0.1:1080 \
      -i /home/loonbac/.ssh/id_ed25519 \
      -o ${lib.escapeShellArg "ProxyCommand=${pkgs.openssl}/bin/openssl s_client -connect 149.34.48.153:8443 -quiet 2>/dev/null"} \
      -o BatchMode=yes \
      -o ConnectTimeout=10 \
      -o ExitOnForwardFailure=yes \
      -o IdentitiesOnly=yes \
      -o ServerAliveInterval=5 \
      -o ServerAliveCountMax=3 \
      -o StrictHostKeyChecking=yes \
      korosoft@vps.korosoft.net
  '';

  tunnelCheck = pkgs.writeShellScript "ts-bypass-tunnel-check" ''
    set -euo pipefail
    for _attempt in $(${pkgs.coreutils}/bin/seq 1 12); do
      if ${pkgs.curl}/bin/curl \
        --fail --silent --show-error --max-time 8 \
        --socks5-hostname 127.0.0.1:1080 \
        --output /dev/null \
        https://derp16b.tailscale.com/derp/latency-check; then
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 1
    done
    echo "El SOCKS no logró alcanzar el relay DERP de Miami." >&2
    exit 1
  '';

  tsBypass = pkgs.callPackage ../../../pkgs/ts-bypass {
    inherit stateHelper;
  };
in
{
  config = lib.mkMerge [
    {
      services.tailscale.enable = true;
    }

    (lib.mkIf isLoonLaptop {
      environment.systemPackages = [ tsBypass ];

      programs.ssh.knownHosts."vps.korosoft.net".publicKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINJDevMVI9rQVrG94a5udGaOW41aRvNcckkki5NA6+M1";

      # El archivo existe únicamente cuando `ts-bypass on` está habilitado.
      # Solo ALL_PROXY es válido aquí: HTTP(S)_PROXY hace que el cliente DERP
      # envíe HTTP CONNECT al SOCKS5 y OpenSSH cierre el canal con EOF.
      systemd.services.tailscaled = {
        after = [ "ts-bypass-tunnel.service" ];
        serviceConfig.EnvironmentFile = "-${environmentFile}";
      };

      systemd.services.ts-bypass-tunnel = {
        description = "Tailscale bypass via supervised SSH-over-TLS SOCKS5 tunnel";
        documentation = [ "https://tailscale.com/docs/" ];
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" "NetworkManager-wait-online.service" ];
        wants = [ "network-online.target" ];
        path = [ pkgs.openssh pkgs.openssl ];
        unitConfig = {
          ConditionPathExists = environmentFile;
          StartLimitIntervalSec = 0;
        };
        serviceConfig = {
          Type = "exec";
          User = "loonbac";
          Group = "users";
          Environment = "HOME=/home/loonbac";
          ExecStart = "${tunnel}";
          ExecStartPost = [ "${tunnelCheck}" ];
          Restart = "always";
          RestartSec = "2s";
          KillMode = "control-group";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = "read-only";
          ReadOnlyPaths = [ "/home/loonbac/.ssh" ];
        };
      };
    })
  ];
}
