# Control de brillo DDC/CI para un monitor externo. Lo consume el backend
# `ddc` de modules/system/brightness.nix; hoy ningún host lo usa (saitina es
# `internal`), así que la derivación solo existe por si se reactiva.
{ pkgs, monitorModel }:

pkgs.writeShellApplication {
  name = "ddc-brightness";
  runtimeInputs = with pkgs; [
    ddcutil
    procps
    systemd
  ];
  text = ''
    # Ruta rápida para input interactivo: el daemon valida y agrupa estos
    # mensajes. Evita arrancar Python por cada muesca de la rueda.
    command="''${1:-}"
    if [ -n "''${XDG_RUNTIME_DIR:-}" ]; then
      control="$XDG_RUNTIME_DIR/ddc-brightness/control"
      case "$command" in
        up|+|down|-|set)
          if [ "$command" = set ]; then
            value="''${2:-}"
          else
            value="''${2:-10}"
          fi
          value="''${value%%%}"
          case "$value" in
            ""|*[!0-9]*) ;;
            *)
              if [ "$value" -le 100 ] && [ -p "$control" ]; then
                case "$command" in
                  +) command=up ;;
                  -) command=down ;;
                esac
                printf '%s %s\n' "$command" "$value" > "$control"
                exit 0
              fi
              ;;
          esac
          ;;
      esac
    fi

    export DDC_BRIGHTNESS_MONITOR_MODEL=${builtins.toJSON monitorModel}
    exec ${pkgs.python3}/bin/python3 ${./ddc-brightness.py} "$@"
  '';
}
