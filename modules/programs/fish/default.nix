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
      # Quita el banner "Welcome to fish" al abrir una consola.
      set fish_greeting

      # Banner de actualizaciones de paquetes disponibles en NixOS (si existen).
      if type -q nixos-updates
        nixos-updates banner
      end

      # Detección automática de binarios: agrega los dirs existentes.
      for dir in \
        ~/.npm-global/bin \
        ~/.cargo/bin \
        ~/go/bin \
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
      # --config usa el tema craver guardado localmente en /etc.
      oh-my-posh init fish --strict --config /etc/oh-my-posh/craver.omp.json | source
    '';
  };

  # Tema craver de oh-my-posh, gestionado por NixOS (versionado en el repo).
  environment.etc."oh-my-posh/craver.omp.json".source = ./craver.omp.json;
}
