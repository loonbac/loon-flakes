import QtQuick
import Quickshell.Io

// Acción puntual: ejecuta un comando y no espera su salida.
//
// Cada acción tiene su propio proceso, así dos clics rápidos en la barra (por
// ejemplo subir el volumen con la rueda) no se pisan entre sí.
QtObject {
    id: accion

    property var comando: []

    function ejecutar() {
        proceso.running = true;
    }

    property Process proceso: Process {
        id: proceso
        command: accion.comando
    }
}
