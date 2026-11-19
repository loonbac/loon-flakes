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
// (bandeja por D-Bus, Bluetooth por BlueZ), así que la barra no necesita
// binarios extra para esas integraciones.
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
        top: 6
        left: 10
        right: 10
    }

    // Alto de reposo de la barra: la píldora central mide 44 px y deja 6 px
    // arriba y abajo. La ventana crece para dibujar la isla expandida, pero la
    // reserva (zona exclusiva) se queda fija en la de reposo (L5).
    readonly property int altoReposo: 56
    readonly property int altoIsla: pildoraCentro.altoActivo + 12

    implicitHeight: barra.islaExpandida ? barra.altoIsla : barra.altoReposo
    // La reserva NO se anima ni crece con la isla: si lo hiciera, niri bajaría
    // las ventanas sólo para darle margen (L5). Se reserva el alto de reposo
    // más el margen superior y la isla expandida pinta por encima.
    // El margen visible superior mide 12 px (6 de la capa + 6 internos). niri
    // añade 8 px de gap a la ventana, así que se restan para que la separación
    // inferior también quede en 12 px.
    exclusiveZone: barra.altoReposo + margins.top - 8

    Behavior on implicitHeight {
        NumberAnimation {
            duration: 300
            easing.type: Easing.OutCubic
        }
    }

    WlrLayershell.namespace: "loon:bar"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // --- Datos de servicios externos ---------------------------------------

    readonly property var reproductor: {
        const lista = Mpris.players.values;
        const navegadores = ["firefox", "chromium", "brave", "helium", "chrome"];
        let elegido = null;
        let navegadorReproduciendo = null;
        for (const candidato of lista) {
            const identidad = String(candidato.identity || "").toLowerCase();
            let esNavegador = false;
            for (const nombre of navegadores) {
                if (identidad.indexOf(nombre) >= 0)
                    esNavegador = true;
            }
            // Prefiere un reproductor dedicado, pero un navegador que esté
            // reproduciendo también cuenta: es lo que el usuario usa a diario
            // y, sin él, no aparece ninguna pista de que la isla está activa.
            if (candidato.isPlaying && !esNavegador)
                return candidato;
            if (candidato.isPlaying && esNavegador && navegadorReproduciendo === null)
                navegadorReproduciendo = candidato;
            if (elegido === null && !esNavegador)
                elegido = candidato;
        }
        return navegadorReproduciendo || elegido;
    }
    readonly property bool reproduccionActiva: barra.reproductor !== null && barra.reproductor.isPlaying

    // La isla sólo se abre mientras el ratón está encima de la card (L5); la
    // reproducción es la condición que la habilita, no la que la despliega.
    property bool ratonSobreIsla: false
    readonly property bool islaExpandida: barra.reproduccionActiva && barra.ratonSobreIsla

    readonly property var adaptadorBluetooth: Bluetooth.defaultAdapter
    readonly property int dispositivosBluetooth: barra.contarBluetooth()

    // --- Utilidades de presentación ----------------------------------------

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

        // Anclada arriba, no centrada: la ventana crece hacia abajo cuando la
        // isla se expande y las píldoras laterales no deben moverse (L5).
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.topMargin: barra.margins.top
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

    // --- Píldora central: la isla ---------------------------------------------
    //
    // Es la única superficie: en reposo muestra la fila de workspaces con la
    // geometría aceptada (44 px de alto, radio 10). Mientras hay reproducción y
    // el ratón está encima, `Workspaces` añade su fila multimedia dentro del
    // mismo rectángulo y la píldora crece en ancho, alto y radio con un pequeño
    // rebote elástico. No hay morph de la celda activa ni ventana emergente
    // aparte (L4). El crecimiento es hacia abajo: el borde superior se queda
    // anclado en la posición aceptada y el inferior invade la ventana de abajo
    // sin desplazarla (L5).
    Rectangle {
        id: pildoraCentro

        readonly property bool activa: barra.islaExpandida
        // Un mínimo evita que la fila multimedia quede apretada cuando el
        // título es corto; en reposo manda el ancho de las celdas. Se mantiene
        // ajustado (210 px) para que la card no se estire hacia la derecha
        // cuando el contenido multimedia es corto (L6).
        readonly property int anchoActivo: Math.max(filaCentro.implicitWidth + 12, 210)
        readonly property int altoActivo: filaCentro.implicitHeight + 12

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: barra.margins.top
        width: pildoraCentro.activa ? pildoraCentro.anchoActivo : filaCentro.implicitWidth + 12
        height: pildoraCentro.activa ? pildoraCentro.altoActivo : 44
        radius: pildoraCentro.activa ? 18 : 10
        color: barra.paleta ? barra.paleta.alfa(barra.paleta.background, 0.88) : "#E011181A"
        border.width: 1
        border.color: barra.paleta ? barra.paleta.alfa(barra.paleta.foreground, 0.25) : "#40F0EDE1"

        Behavior on width {
            NumberAnimation {
                duration: 300
                easing.type: Easing.OutBack
                easing.overshoot: 1.05
            }
        }

        Behavior on height {
            NumberAnimation {
                duration: 300
                easing.type: Easing.OutBack
                easing.overshoot: 1.05
            }
        }

        Behavior on radius {
            NumberAnimation {
                duration: 300
                easing.type: Easing.OutBack
                easing.overshoot: 1.05
            }
        }

        // La fila se ancla arriba, no centrada: con la card creciendo hacia
        // abajo las celdas de workspace se quedan donde estaban y la fila
        // multimedia aparece debajo, dentro de la misma superficie.
        Workspaces {
            id: filaCentro

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: 6
            estado: barra.estado
            paleta: barra.paleta
            reproductor: barra.reproductor
            expandida: barra.islaExpandida
            salida: barra.pantalla ? barra.pantalla.name : ""
        }

        // Hover de la card: `Qt.NoButton` deja pasar los clics a las celdas de
        // workspace que quedan debajo; sólo mide la presencia del ratón.
        Timer {
            id: retardoEntradaIsla
            interval: 120
            repeat: false
            onTriggered: {
                if (zonaHoverIsla.containsMouse)
                    barra.ratonSobreIsla = true;
            }
        }

        MouseArea {
            id: zonaHoverIsla

            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            hoverEnabled: true
            onContainsMouseChanged: {
                if (containsMouse) {
                    retardoEntradaIsla.restart();
                } else {
                    retardoEntradaIsla.stop();
                    barra.ratonSobreIsla = false;
                }
            }
        }
    }

    // --- Píldora derecha ---------------------------------------------------

    Rectangle {
        id: pildoraDerecha

        // Igual que la izquierda: arriba y sin moverse cuando la ventana crece.
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: barra.margins.top
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
