import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Mpris
import Quickshell.Bluetooth

// Barra de estado de la sesión Niri: una ventana layer-shell por monitor.
//
// La estructura reproduce la barra anterior: dos píldoras laterales con los
// módulos y una central con los workspaces de niri. Los datos vienen de
// `Estado.qml` (comandos del sistema) y de los servicios de Quickshell
// (bandeja y MPRIS por D-Bus, Bluetooth por BlueZ), así que la barra no necesita
// binarios extra para esas tres integraciones.
PanelWindow {
    id: barra

    property var paleta: null
    property var estado: null

    // `Variants` de `shell.qml` inyecta aquí el objeto del modelo: una ShellScreen
    // por monitor. No se declara como `pantalla` porque el nombre de la
    // propiedad inyectada lo fija Quickshell.
    property var modelData: null
    readonly property var pantalla: barra.modelData

    screen: barra.pantalla
    color: "transparent"
    focusable: false

    anchors {
        top: true
        left: true
        right: true
    }

    margins {
        top: 0
        left: 10
        right: 10
    }

    implicitHeight: 44
    // La barra toca el borde superior; reservar ese alto evita que niri
    // coloque ventanas debajo.
    exclusiveZone: implicitHeight + margins.top

    WlrLayershell.namespace: "loon:bar"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // --- Datos de servicios externos ---------------------------------------

    // MPRIS: se ignora el reproductor genérico de los navegadores, igual que
    // hacía la configuración anterior, y se prefiere el que está sonando.
    readonly property var reproductor: {
        const lista = Mpris.players.values;
        const ignorados = ["firefox", "chromium", "brave"];
        let elegido = null;
        for (const candidato of lista) {
            const identidad = String(candidato.identity || "").toLowerCase();
            let ignorado = false;
            for (const nombre of ignorados) {
                if (identidad.indexOf(nombre) >= 0)
                    ignorado = true;
            }
            if (ignorado)
                continue;
            if (elegido === null)
                elegido = candidato;
            if (candidato.isPlaying) {
                elegido = candidato;
                break;
            }
        }
        return elegido;
    }

    readonly property var adaptadorBluetooth: Bluetooth.defaultAdapter
    readonly property int dispositivosBluetooth: barra.contarBluetooth()

    // --- Utilidades de presentación ----------------------------------------

    function recortar(texto) {
        // Mismo límite de 25 caracteres que tenía el módulo anterior.
        if (texto.length <= 25)
            return texto;
        return texto.slice(0, 24) + "…";
    }

    function contarBluetooth() {
        const adaptador = barra.adaptadorBluetooth;
        if (adaptador === null || !adaptador.enabled)
            return 0;
        const dispositivos = adaptador.devices;
        let total = 0;
        for (let i = 0; i < dispositivos.length; i++) {
            if (dispositivos[i].connected)
                total += 1;
        }
        return total;
    }

    function tooltipBluetooth() {
        const adaptador = barra.adaptadorBluetooth;
        if (adaptador === null)
            return "Sin adaptador Bluetooth";
        if (!adaptador.enabled)
            return "Bluetooth desactivado";
        const nombres = [];
        const dispositivos = adaptador.devices;
        for (let i = 0; i < dispositivos.length; i++) {
            const dispositivo = dispositivos[i];
            if (dispositivo.connected)
                nombres.push(dispositivo.name || dispositivo.address);
        }
        if (nombres.length === 0)
            return "Sin dispositivos conectados";
        return "Dispositivos conectados: " + nombres.length + "\n" + nombres.join("\n");
    }

    function iconoUpdates() {
        switch (barra.estado.updatesAlt) {
        case "has-updates":
            return "\u{F03D6}";
        case "updated":
            return "\u{F012C}";
        case "checking":
            return "\u{F0450}";
        case "error":
            return "\u{F0026}";
        case "stale":
        case "unknown":
            return "\u{F02FC}";
        }
        return "\u{F02FC}";
    }

    function colorUpdates() {
        if (!barra.paleta)
            return "#F0EDE1";
        switch (barra.estado.updatesAlt) {
        case "has-updates":
            return barra.paleta.highlight;
        case "updated":
            return barra.paleta.muted;
        case "checking":
        case "stale":
        case "unknown":
            return barra.paleta.warning;
        case "error":
            return barra.paleta.critical;
        }
        return barra.paleta.highlight;
    }

    function iconoBrillo() {
        switch (barra.estado.brilloAlt) {
        case "low":
            return "\u{F00DE}";
        case "medium":
            return "\u{F00DF}";
        case "high":
            return "\u{F00E0}";
        }
        return "";
    }

    function iconoVolumen() {
        const estado = barra.estado;
        if (estado.salidaSilenciada)
            return "\u{F075F}";
        if (estado.volumenSalida >= 67)
            return "\uF028";
        if (estado.volumenSalida >= 34)
            return "\uF027";
        return "\uF026";
    }

    function tooltipSalida() {
        const estado = barra.estado;
        let texto = estado.salidaSilenciada ? "Silenciado" : "Volumen: " + estado.volumenSalida + "%";
        if (estado.salidaDescripcion !== "")
            texto += "\n" + estado.salidaDescripcion;
        return texto;
    }

    function iconoRed() {
        const estado = barra.estado;
        if (estado.redTipo === "ethernet")
            return "\u{F0200}";
        if (estado.redTipo === "none")
            return "\u{F092E}";
        if (estado.redSenal >= 80)
            return "\u{F0928}";
        if (estado.redSenal >= 60)
            return "\u{F0925}";
        if (estado.redSenal >= 40)
            return "\u{F0922}";
        if (estado.redSenal >= 20)
            return "\u{F091F}";
        return "\u{F092F}";
    }

    function textoRed() {
        const estado = barra.estado;
        if (estado.redTipo === "wifi")
            return estado.redNombre;
        if (estado.redTipo === "ethernet")
            return estado.redIp;
        return "";
    }

    function cargando() {
        return barra.estado.bateriaEstado === "Charging";
    }

    function iconoBateria() {
        const estado = barra.estado;
        const baterias = ["\u{F007A}", "\u{F007B}", "\u{F007C}", "\u{F007D}", "\u{F007E}",
            "\u{F007F}", "\u{F0080}", "\u{F0081}", "\u{F0082}", "\u{F0079}"];
        const cargando = ["\u{F089C}", "\u{F0086}", "\u{F0087}", "\u{F0088}", "\u{F089D}",
            "\u{F0089}", "\u{F089E}", "\u{F008A}", "\u{F008B}", "\u{F0085}"];
        const indice = Math.max(0, Math.min(9, Math.floor(estado.bateriaCarga / 10)));
        if (estado.bateriaEstado === "Charging")
            return cargando[indice];
        if (estado.bateriaEstado === "Full")
            return "\u{F0085}";
        if (estado.bateriaEstado === "Not charging")
            return "\uF1E6";
        return baterias[indice];
    }

    function colorBateria() {
        const estado = barra.estado;
        if (!barra.paleta)
            return "#F0EDE1";
        if (estado.bateriaEstado === "Charging")
            return barra.paleta.accent;
        if (estado.bateriaCarga <= 10)
            return barra.paleta.critical;
        if (estado.bateriaCarga <= 20)
            return barra.paleta.warning;
        return barra.paleta.foreground;
    }

    function tooltipBateria() {
        const estado = barra.estado;
        let situacion = "Descargando";
        if (estado.bateriaEstado === "Charging")
            situacion = "Cargando";
        else if (estado.bateriaEstado === "Full")
            situacion = "Completa";
        return "Batería: " + estado.bateriaCarga + "%\n" + situacion;
    }

    // --- Píldora izquierda -------------------------------------------------

    Rectangle {
        id: pildoraIzquierda

        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: filaIzquierda.implicitWidth + 20
        height: 44
        radius: 10
        color: barra.paleta ? barra.paleta.alfa(barra.paleta.background, 0.88) : "#E011181A"
        border.width: 1
        border.color: barra.paleta ? barra.paleta.alfa(barra.paleta.foreground, 0.25) : "#40F0EDE1"

        Row {
            id: filaIzquierda

            anchors.centerIn: parent
            spacing: 2

            // Lanzador: clic izquierdo abre el launcher, derecho una terminal.
            Boton {
                paleta: barra.paleta
                icono: "\u{F1105}"
                tamanoIcono: 18
                colorIcono: barra.paleta ? barra.paleta.accent : "#AB9A5E"
                tooltip: "Loon Launch\n\nSuper + Space"
                onClic: barra.estado.accionLanzador.ejecutar()
                onClicDerecho: barra.estado.accionTerminal.ejecutar()
            }

            // Reloj con calendario en el globo.
            Reloj {
                paleta: barra.paleta
                estado: barra.estado
            }

            // Inhibidor de inactividad (bloquea el apagado de pantalla).
            Boton {
                paleta: barra.paleta
                icono: barra.estado.inhibidorActivo ? "\u{F06CA}" : "\u{F0FAB}"
                colorIcono: barra.estado.inhibidorActivo
                    ? (barra.paleta ? barra.paleta.accent : "#AB9A5E")
                    : (barra.paleta ? barra.paleta.foreground : "#F0EDE1")
                tooltip: barra.estado.inhibidorActivo ? "Idle Inhibitor: Activo" : "Idle Inhibitor: Inactivo"
                onClic: barra.estado.alternarInhibidor()
            }

            // Reproductor MPRIS.
            Boton {
                paleta: barra.paleta
                habilitado: barra.reproductor !== null
                icono: barra.reproductor && barra.reproductor.isPlaying ? "\u{F02CE}" : "⏸"
                texto: barra.reproductor ? barra.recortar(barra.reproductor.trackTitle || "") : ""
                colorTexto: barra.reproductor && barra.reproductor.isPlaying
                    ? (barra.paleta ? barra.paleta.foreground : "#F0EDE1")
                    : (barra.paleta ? barra.paleta.muted : "#8C8877")
                tooltip: barra.reproductor
                    ? (barra.reproductor.trackArtist || barra.reproductor.identity) + "\n" + (barra.reproductor.trackTitle || "")
                    : ""
                onClic: {
                    const jugador = barra.reproductor;
                    if (jugador && jugador.canTogglePlaying)
                        jugador.togglePlaying();
                }
                onRuedaArriba: {
                    const jugador = barra.reproductor;
                    if (jugador && jugador.canGoNext)
                        jugador.next();
                }
                onRuedaAbajo: {
                    const jugador = barra.reproductor;
                    if (jugador && jugador.canGoPrevious)
                        jugador.previous();
                }
            }

            // Bandeja del sistema.
            Bandeja {
                paleta: barra.paleta
                ventana: barra
            }

            // Estado de actualizaciones de NixOS: clic derecho fuerza la
            // comprobación en segundo plano.
            Boton {
                paleta: barra.paleta
                icono: barra.iconoUpdates()
                texto: barra.estado.updatesTexto
                colorIcono: barra.colorUpdates()
                tooltip: barra.estado.updatesTooltip
                onClicDerecho: barra.estado.accionComprobarUpdates.ejecutar()
            }
        }
    }

    // --- Píldora central: workspaces de niri -------------------------------

    Rectangle {
        id: pildoraCentro

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        width: filaCentro.implicitWidth + 12
        height: 44
        radius: 10
        color: barra.paleta ? barra.paleta.alfa(barra.paleta.background, 0.88) : "#E011181A"
        border.width: 1
        border.color: barra.paleta ? barra.paleta.alfa(barra.paleta.foreground, 0.25) : "#40F0EDE1"

        Workspaces {
            id: filaCentro

            anchors.centerIn: parent
            estado: barra.estado
            paleta: barra.paleta
            salida: barra.pantalla ? barra.pantalla.name : ""
        }
    }

    // --- Píldora derecha ---------------------------------------------------

    Rectangle {
        id: pildoraDerecha

        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: filaDerecha.implicitWidth + 20
        height: 44
        radius: 10
        color: barra.paleta ? barra.paleta.alfa(barra.paleta.background, 0.88) : "#E011181A"
        border.width: 1
        border.color: barra.paleta ? barra.paleta.alfa(barra.paleta.foreground, 0.25) : "#40F0EDE1"

        Row {
            id: filaDerecha

            anchors.centerIn: parent
            spacing: 2

            // Brillo de pantalla: rueda para subir y bajar de 5 en 5.
            Boton {
                paleta: barra.paleta
                habilitado: barra.estado.brilloVisible
                icono: barra.iconoBrillo()
                texto: barra.estado.brilloTexto
                tooltip: barra.estado.brilloTooltip
                onRuedaArriba: {
                    barra.estado.accionBrilloArriba.ejecutar();
                    barra.estado.refrescarBrillo();
                }
                onRuedaAbajo: {
                    barra.estado.accionBrilloAbajo.ejecutar();
                    barra.estado.refrescarBrillo();
                }
            }

            // Bluetooth (BlueZ por D-Bus, sin bluetoothctl).
            Boton {
                paleta: barra.paleta
                habilitado: barra.adaptadorBluetooth !== null
                icono: {
                    const adaptador = barra.adaptadorBluetooth;
                    if (adaptador === null)
                        return "";
                    if (!adaptador.enabled)
                        return "\u{F00B2}";
                    return barra.dispositivosBluetooth > 0 ? "\u{F00B1}" : "\u{F00AF}";
                }
                texto: barra.dispositivosBluetooth > 0 ? String(barra.dispositivosBluetooth) : ""
                colorIcono: {
                    const adaptador = barra.adaptadorBluetooth;
                    if (adaptador === null || !barra.paleta)
                        return "#F0EDE1";
                    if (!adaptador.enabled)
                        return barra.paleta.muted;
                    return barra.dispositivosBluetooth > 0 ? barra.paleta.highlight : barra.paleta.foreground;
                }
                tooltip: barra.tooltipBluetooth()
            }

            // Volumen de salida.
            Boton {
                paleta: barra.paleta
                icono: barra.iconoVolumen()
                texto: barra.estado.salidaSilenciada ? "off" : barra.estado.volumenSalida + "%"
                colorTexto: barra.estado.salidaSilenciada
                    ? (barra.paleta ? barra.paleta.muted : "#8C8877")
                    : (barra.paleta ? barra.paleta.foreground : "#F0EDE1")
                tooltip: barra.tooltipSalida()
                onClic: {
                    barra.estado.alternarSalida();
                }
                onRuedaArriba: {
                    barra.estado.subirSalida();
                }
                onRuedaAbajo: {
                    barra.estado.bajarSalida();
                }
            }

            // Volumen del micrófono.
            Boton {
                paleta: barra.paleta
                icono: barra.estado.entradaSilenciada ? "\uF131" : "\uF130"
                colorIcono: barra.estado.entradaSilenciada
                    ? (barra.paleta ? barra.paleta.muted : "#8C8877")
                    : (barra.paleta ? barra.paleta.foreground : "#F0EDE1")
                tooltip: barra.estado.entradaSilenciada
                    ? "Micrófono: silenciado"
                    : "Micrófono: " + barra.estado.volumenEntrada + "%"
                onClic: {
                    barra.estado.alternarEntrada();
                }
                onRuedaArriba: {
                    barra.estado.subirEntrada();
                }
                onRuedaAbajo: {
                    barra.estado.bajarEntrada();
                }
            }

            // Red: cable o wifi principal.
            Boton {
                paleta: barra.paleta
                icono: barra.iconoRed()
                texto: barra.textoRed()
                colorIcono: barra.estado.redTipo === "none"
                    ? (barra.paleta ? barra.paleta.critical : "#E6506B")
                    : (barra.paleta ? barra.paleta.foreground : "#F0EDE1")
                tooltip: barra.estado.redTooltip
            }

            // Memoria usada: clic abre btop.
            Boton {
                paleta: barra.paleta
                icono: "\uE266"
                texto: barra.estado.memoriaUsada.toFixed(1) + "G"
                tooltip: "Memoria: " + barra.estado.memoriaUsada.toFixed(1) + "GB / "
                    + barra.estado.memoriaTotal.toFixed(1) + "GB"
                onClic: barra.estado.accionMonitor.ejecutar()
            }

            // CPU: clic abre btop.
            Boton {
                paleta: barra.paleta
                icono: "\uF4BC"
                texto: barra.estado.cpuUso + "%"
                tooltip: "CPU: " + barra.estado.cpuUso + "%"
                onClic: barra.estado.accionMonitor.ejecutar()
            }

            // Batería: oculta si el equipo no tiene ninguna.
            Boton {
                paleta: barra.paleta
                habilitado: barra.estado.bateriaPresente
                icono: barra.iconoBateria()
                texto: barra.estado.bateriaCarga + "%"
                colorTexto: barra.colorBateria()
                tooltip: barra.tooltipBateria()
            }
        }
    }
}
