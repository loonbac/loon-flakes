//@ pragma UseQApplication
import QtQuick
import Quickshell

// Los menus contextuales de la bandeja se dibujan con QtWidgets. Sin este
// pragma, SystemTrayItem.display() falla en silencio y el click derecho
// no muestra ninguna opcion.

// Entrada del shell: el servicio lo arranca con `qs -p /etc/quickshell/loonbar`.
//
// La paleta y el estado se crean una sola vez aquí y se comparten entre todas
// las pantallas. `LOON_BAR_SCREEN` permite elegir una sola salida; si está
// vacío, `Variants` instancia una barra por pantalla como antes.
ShellRoot {
    id: raiz

    readonly property string pantallaDeseada: Quickshell.env("LOON_BAR_SCREEN") || ""
    readonly property var pantallasBarra: pantallaDeseada !== ""
        ? Quickshell.screens.filter(function (pantalla) { return pantalla.name === pantallaDeseada; })
        : Quickshell.screens

    Paleta {
        id: paletaGlobal
    }

    Estado {
        id: estadoGlobal
    }

    Variants {
        model: raiz.pantallasBarra

        delegate: Component {
            Barra {
                paleta: paletaGlobal
                estado: estadoGlobal
            }
        }
    }
}
