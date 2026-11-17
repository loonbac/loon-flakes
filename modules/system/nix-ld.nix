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
      # Loader de Vulkan (libvulkan.so.1): los binarios externos lo hacen
      # dlopen en vez de enlazarlo, y sin esta entrada Ryujinx Nextendo (y
      # cualquier app Vulkan descargada) no encuentra el loader aunque mesa
      # y libglvnd ya estén aquí.
      vulkan-loader
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
      # Sesión X11 de Avalonia (Ryujinx): IceAddConnectionWatch necesita
      # libICE.so.6 y sin ella la app aborta al crear la ventana.
      libICE
      libSM
    ];
  };
}
