import QtQuick
import Quickshell

// Entrada del shell: el servicio lo arranca con `qs -p /etc/quickshell/loonbar`.
//
// La paleta y el estado se crean una sola vez aquí y se comparten entre todas
// las pantallas; cada monitor recibe su propia barra con `Variants`, que
// instancia una ventana layer-shell por pantalla.
ShellRoot {
    id: raiz

    Paleta {
        id: paletaGlobal
    }

    Estado {
        id: estadoGlobal
    }

    Variants {
        model: Quickshell.screens

        delegate: Component {
            Barra {
                paleta: paletaGlobal
                estado: estadoGlobal
            }
        }
    }
}
