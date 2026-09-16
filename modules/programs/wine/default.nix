# Wine: integración de ejecutables Windows con el escritorio y la shell.
# El módulo mantiene juntos el runtime, el launcher, MIME y binfmt porque
# cambian por la misma razón: ejecutar PE locales con una sola convención.
{ lib, pkgs, ... }:

let
  winePackage = pkgs.wineWow64Packages.stable;
  wineExecutable = lib.getExe winePackage;

  windowsExecutableMimeTypes = [
    "application/vnd.microsoft.portable-executable"
    "application/x-dosexec"
    "application/x-ms-ne-executable"
    "application/x-msdownload"
    "application/x-msi"
  ];

  wineExeLauncher = pkgs.writeShellScriptBin "wine-exe" ''
    set -eu

    if [ "$#" -eq 0 ]; then
      printf '%s\n' 'Uso: wine-exe archivo.exe [argumentos...]' >&2
      exit 64
    fi

    # Wine 11 intenta EGL por defecto; en esta sesión NVIDIA + XWayland el
    # backend GLX es el que ofrece los formatos que SDL necesita.
    if ! ${wineExecutable} reg add 'HKCU\Software\Wine\X11 Driver' \
      /v UseEGL /t REG_SZ /d N /f >/dev/null 2>&1; then
      printf '%s\n' 'wine-exe: no se pudo preparar el backend gráfico de Wine' >&2
      exit 1
    fi

    executable="$1"
    shift

    # Los ejecutables locales se abren desde su propia carpeta. Esto conserva
    # la resolución de recursos relativa que esperan muchos programas Windows.
    if [ -f "$executable" ]; then
      executable_dir="$(${pkgs.coreutils}/bin/dirname -- "$executable")"
      executable_dir="$(${pkgs.coreutils}/bin/realpath -- "$executable_dir")"
      executable="$executable_dir/$(${pkgs.coreutils}/bin/basename -- "$executable")"
      cd -- "$executable_dir"
    fi

    exec ${wineExecutable} "$executable" "$@"
  '';

  wineDesktopItem = pkgs.makeDesktopItem {
    name = "wine-exe";
    desktopName = "Wine (ejecutable de Windows)";
    genericName = "Ejecutable de Windows";
    comment = "Abrir ejecutables Windows con Wine";
    exec = "${lib.getExe wineExeLauncher} %f";
    tryExec = wineExecutable;
    terminal = false;
    noDisplay = true;
    mimeTypes = windowsExecutableMimeTypes;
    categories = [ "System" ];
    startupNotify = false;
  };
in
{
  environment.systemPackages = [
    winePackage
    pkgs.winetricks
    wineExeLauncher
    wineDesktopItem
  ];

  # Permite ejecutar un PE marcado como ejecutable con `./programa.exe`.
  # Los archivos descargados sin bit x siguen funcionando con doble clic o
  # mediante `wine-exe`, que no exige cambiar sus permisos.
  boot.binfmt.registrations.wine-pe = {
    recognitionType = "magic";
    offset = 0;
    magicOrExtension = "MZ";
    interpreter = "${lib.getExe wineExeLauncher}";
    wrapInterpreterInShell = false;
  };

  xdg.mime = {
    addedAssociations = lib.genAttrs windowsExecutableMimeTypes (_: "wine-exe.desktop");
    defaultApplications = lib.genAttrs windowsExecutableMimeTypes (_: "wine-exe.desktop");
  };
}
