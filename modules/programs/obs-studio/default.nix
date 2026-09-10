# OBS se declara mediante su módulo NixOS para que el wrapper oficial pueda
# componer plugins sin copiar archivos al perfil ni al home del usuario.
{ ... }:

{
  programs.obs-studio.enable = true;
}
