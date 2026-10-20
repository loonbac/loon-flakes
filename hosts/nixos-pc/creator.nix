# Creación de vídeo en el PC de escritorio.
#
# Drift (CutWire Studios) es un editor de vídeo GPL-3.0 que upstream publica por
# su canal oficial en Flathub, así que se declara el id de la app y NixOS lo
# instala y lo mantiene actualizado desde ese canal: sin versión fijada, sin
# hash manual y sin bytes propios que reconciliar (ver AGENTS.md, política de
# versiones).
#
# El manifiesto de Flathub ya concede lo que la app necesita dentro del
# sandbox: `--share=network`, Wayland con fallback a X11, PulseAudio, IPC y
# `--device=dri` para los efectos y transiciones de GPU. El acceso a medios va
# por portales, que en esta sesión ya funcionan, así que no se amplía el
# sandbox; si el selector de archivos resultara incómodo, el arreglo es un
# override con `filesystems = [ "home" ]`, como el de PokeMMO en gaming.nix.
{ ... }:

{
  services.flatpak.packages = [ "org.cutwire.Drift" ];
}
