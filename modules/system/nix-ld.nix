# Compatibilidad para ejecutables ELF dinámicos descargados fuera de Nix.
# Los binarios aún necesitan coincidir con la arquitectura y sus bibliotecas
# deben estar disponibles aquí o venir empaquetadas con la aplicación.
{ pkgs, ... }:

{
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      stdenv.cc.cc.lib
      zlib
      libvlc
      openssl
      curl
      expat
      icu
      nss
      nspr
      dbus
      glib
      gtk3
      fontconfig
      freetype
      alsa-lib
      libpulseaudio
      libusb1
      libglvnd
      mesa
      libdrm
      libgbm
      libx11
      libxcb
      libxext
      libxrender
      libxcursor
      libxrandr
      libxi
      libxinerama
      libxfixes
      libxcomposite
      libxdamage
      libxscrnsaver
      libxtst
      libxkbcommon
    ];
  };
}
