# Host de escritorio ASRock B550 Pro4 (Ryzen 7 5700X + NVIDIA).
{ ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./platform.nix
    ./games-disk.nix
    ./projects-disk.nix
    ./gaming.nix
    ./moonshine.nix
  ];

  networking.hostName = "nixos-pc";

  # Este equipo usa un teclado físico ANSI estadounidense.
  services.xserver.xkb.layout = "us";
  console.keyMap = "us";

  system.stateVersion = "26.05";
}
