{ pkgs, ... }:

let
  bridge = pkgs.callPackage ../../../pkgs/pi-ssh-clipboard { };
in
{
  environment.systemPackages = [ bridge ];

  # OpenSSH forwards a private Unix socket instead of a TCP port. The remote
  # xclip-compatible shim used by Pi can therefore read an image only while
  # this exact SSH connection is alive.
  programs.ssh.extraConfig = ''
    Host 192.168.0.2 192.168.0.10 100.81.168.104 100.73.247.39 loon-laptop nixos-pc
      RemoteForward /run/user/1000/pi-ssh-clipboard.sock /run/user/1000/pi-clipboard-source.sock
      StreamLocalBindMask 0177
      StreamLocalBindUnlink yes
  '';

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
