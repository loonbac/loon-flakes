# Módulo "programs/fish": shell fish con detección automática de binarios.
#
# conf.d/path.fish agrega al PATH todos los directorios de binarios que
# existan (npm-global, cargo, pip, etc.), de forma recursiva. Así, cualquier
# paquete instalado globalmente (npm i -g, cargo install, ...) se puede
# ejecutar con su comando sin configurar nada a mano.
{ config, lib, pkgs, ... }:

{
  programs.fish = {
    enable = true;
    interactiveShellInit = ''
      # Detección automática de binarios: agrega los dirs existentes.
      for dir in \
        ~/.npm-global/bin \
        ~/.cargo/bin \
        ~/.local/bin \
        ~/.local/share/pipx/venvs/*/bin \
        ~/.local/state/nix/profile/bin \
        ~/.nix-profile/bin
        if test -d $dir
          fish_add_path --prepend --move $dir
        end
      end

      # Prompt personalizado: Oh My Posh.
      # --strict resuelve `oh-my-posh` por PATH (correcto con el store de Nix).
      oh-my-posh init fish --strict | source
    '';
  };
}
