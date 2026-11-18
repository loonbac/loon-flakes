import QtQuick
import Quickshell.Io

// Sondeo de un comando: expone su stdout y, si `intervalo` es mayor que cero,
// lo repite periódicamente.
//
// La barra nunca reinicia el proceso desde `onRunningChanged` (eso reentra en el
// propio proceso); el temporizador solo dispara cuando no hay nada corriendo, así
// que un comando lento no apila ejecuciones ni deja procesos huérfanos.
//
// Con `intervalo: 0` queda como comando puntual: hay que llamar a `trigger()`.
QtObject {
    id: sondeo

    property var comando: []
    property int intervalo: 0
    property string texto: ""
    property int codigoSalida: 0

    readonly property bool corriendo: proceso.running

    // Lanza el comando una vez. Si ya hay uno en curso se ignora: la siguiente
    // vuelta del temporizador lo reintentará.
    function trigger() {
        if (proceso.running)
            return;
        proceso.running = true;
    }

    // Corta el proceso en curso (SIGTERM).
    function detener() {
        proceso.running = false;
    }

    property Timer temporizador: Timer {
        running: sondeo.intervalo > 0
        repeat: true
        interval: sondeo.intervalo
        onTriggered: sondeo.trigger()
    }

    property Process proceso: Process {
        id: proceso
        command: sondeo.comando
        stdout: StdioCollector {
            id: salida
            onStreamFinished: sondeo.texto = salida.text
        }
        onExited: (codigo, estado) => {
            sondeo.codigoSalida = codigo;
        }
    }

    // Primer sondeo inmediato: sin esto la barra queda vacía hasta el primer tick.
    Component.onCompleted: {
        if (sondeo.intervalo > 0)
            sondeo.trigger();
    }
}
