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
{ config, lib, ... }:

let
  # La extensión GL de NVIDIA para Flatpak coloca sus bibliotecas bajo una ruta
  # que lleva la versión del driver (…/GL/nvidia-<driver>/lib) y el runtime no la
  # añade al camino de búsqueda del cargador. Consecuencia medida en esta
  # máquina: OpenGL sí funciona (GLVND apunta ahí de forma explícita), pero
  # `dlopen("libcuda.so.1")` falla — y por eso NVENC no se puede abrir al
  # exportar, aunque el informe de la app liste `h264_nvenc` como soportado.
  #
  # El id de la extensión codifica la versión del driver con guiones, así que la
  # ruta se deriva del paquete del driver en vez de fijarla como texto: subir el
  # driver rompería la cadena en silencio si esto fuera una constante.
  nvidiaExtensionLibs = "/usr/lib/x86_64-linux-gnu/GL/nvidia-${lib.replaceStrings [ "." ] [ "-" ] config.hardware.nvidia.package.version}/lib";
in

{
  services.flatpak.packages = [ "org.cutwire.Drift" ];

  # Solo para esta app: `LD_LIBRARY_PATH` antepone rutas al cargador y hacerlo
  # global podría ensombrecer bibliotecas de otras aplicaciones. Se usa
  # `overrides.settings`, la forma vigente de nix-flatpak: la forma corta que
  # usa `gaming.nix` está deprecada y emite aviso al activar.
  services.flatpak.overrides.settings."org.cutwire.Drift".Environment.LD_LIBRARY_PATH = nvidiaExtensionLibs;
}
