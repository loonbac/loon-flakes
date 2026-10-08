{ config, pkgs, lib, helium-browser, ... }:

# Panel de nueva pestaña de Helium.
#
# Dos piezas que tienen que ir juntas: el archivo de política que le dice al navegador
# qué abrir en una pestaña nueva, y el servicio que reescribe ese archivo con el estado
# actual. Sin el servicio la página queda congelada en el momento en que se instaló.
#
# La política es una política gestionada, así que Helium no deja cambiarla desde su
# interfaz. Es deliberado: la página es la misma para todas las pestañas y para las
# ventanas de incógnito, así que no hay nada que elegir por perfil.
let
  newtabDashboard = pkgs.callPackage ../../pkgs/newtab-dashboard { };

  # El escritorio lo genera `accent-wallpaper`; este servicio lo vuelve a correr cuando
  # cambia el fondo de pantalla para que el acento de la página siga al del escritorio en
  # lugar de esperar al siguiente ciclo del temporizador.
  user = "loonbac";
  home = "/home/loonbac";
  pagePath = "${home}/.local/share/newtab/index.html";
in
{
  environment.systemPackages = [
    newtabDashboard
    # Helium tal como lo lanza el escritorio, con el flag que deja a la pagina leer su
    # propio archivo de datos. Sin el, el navegador trata cada file:// como un origen
    # distinto y bloquea la lectura, y el panel solo puede refrescarse recargandose.
    (pkgs.symlinkJoin {
      name = "helium";
      paths = [ helium-browser ];
      postBuild = ''
        for desktop in $out/share/applications/*.desktop; do
          sed -i "s|^Exec=helium|Exec=${helium-browser}/bin/helium --allow-file-access-from-files|" "$desktop"
          sed -i "s|^TryExec=helium|TryExec=${helium-browser}/bin/helium|" "$desktop"
        done
      '';
    })
  ];

  # La ruta la lee el propio Helium: el binario contiene literalmente
  # "/etc/chromium/policies", así que no hay que adivinar dónde buscar.
  environment.etc."chromium/policies/managed/00-newtab.json".text = builtins.toJSON {
    NewTabPageLocation = "file://${pagePath}";
  };

  systemd.services.newtab-dashboard = {
    description = "Genera el panel de nueva pestaña de Helium";
    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = "users";
      Environment = [ "HOME=${home}" ];
      ExecStart = "${newtabDashboard}/bin/newtab-dashboard --quiet";
      # El generador lee las sesiones de Pi, que pueden estar escribiéndose mientras
      # corre. Es lectura, así que lo único que importa es que no se acumulen corridas
      # si una tarda más que su intervalo.
      Nice = 10;
    };
  };

  systemd.timers.newtab-dashboard = {
    description = "Refresca el panel de nueva pestaña";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      # Cada cuatro segundos: la cache deja el trabajo en menos de medio segundo, y el
      # panel tiene que verse moverse para que sirva de algo mirarlo.
      OnUnitActiveSec = "4s";
      Unit = "newtab-dashboard.service";
    };
  };

  # La primera generación no debe esperar al primer disparo del temporizador: si el
  # archivo no existe, la pestaña nueva abre un error de archivo no encontrado.
  systemd.services.newtab-dashboard.wantedBy = [ "multi-user.target" ];
}
