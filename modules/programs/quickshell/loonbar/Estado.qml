import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import Quickshell.Services.Pipewire

// Estado compartido por todas las barras (una por monitor).
//
// Cada dato se consulta una sola vez aunque haya varias pantallas: aquí viven
// los sondeos y las acciones, y `Barra.qml` solo los presenta. Todo se obtiene
// de comandos del sistema, salvo lo que Quickshell ya trae como servicio
// (trayectoria, bandeja y Bluetooth se leen en `Barra.qml` desde sus módulos).
QtObject {
    id: estado

    // La unidad inyecta el backend configurado en NixOS (sysfs o DDC/CI).
    readonly property string comandoBrillo: Quickshell.env("LOON_BRIGHTNESS_COMMAND") || "screen-brightness"

    // --- Reloj -------------------------------------------------------------

    // SystemClock emite en el instante exacto del segundo, sin lanzar un
    // proceso ni depender de un Timer que se desfasa.
    property SystemClock relojSistema: SystemClock {
        precision: SystemClock.Seconds
    }
    readonly property date ahora: estado.relojSistema.date

    // --- Workspaces de niri -------------------------------------------------

    // Un solo stream IPC para todo el shell: niri envía el estado completo al
    // conectar y después eventos incrementales. No hay sondeo ni un proceso
    // por monitor.
    property var workspaces: []

    function activarWorkspace(id, enfocado) {
        const actuales = estado.workspaces;
        let objetivo = null;
        for (let i = 0; i < actuales.length; i++) {
            if (actuales[i].id === id)
                objetivo = actuales[i];
        }
        const salida = objetivo !== null ? objetivo.output : null;
        const nuevo = [];
        for (let i = 0; i < actuales.length; i++) {
            const copia = Object.assign({}, actuales[i]);
            if (salida !== null && copia.output === salida)
                copia.is_active = false;
            copia.is_focused = false;
            if (copia.id === id) {
                copia.is_active = true;
                copia.is_focused = enfocado;
            }
            nuevo.push(copia);
        }
        estado.workspaces = nuevo;
    }

    function procesarEventoNiri(linea) {
        const texto = String(linea).trim();
        if (texto === "")
            return;
        let evento;
        try {
            evento = JSON.parse(texto);
        } catch (error) {
            return;
        }
        if (evento.WorkspacesChanged !== undefined) {
            estado.workspaces = evento.WorkspacesChanged.workspaces || [];
        } else if (evento.WorkspaceActivated !== undefined) {
            estado.activarWorkspace(evento.WorkspaceActivated.id,
                                    evento.WorkspaceActivated.focused === true);
        } else if (evento.WorkspaceUrgencyChanged !== undefined) {
            estado.cambiarWorkspace(evento.WorkspaceUrgencyChanged.id,
                                    { is_urgent: evento.WorkspaceUrgencyChanged.urgent === true });
        } else if (evento.WorkspaceActiveWindowChanged !== undefined) {
            estado.cambiarWorkspace(evento.WorkspaceActiveWindowChanged.id,
                                    { active_window_id: evento.WorkspaceActiveWindowChanged.window_id });
        }
    }

    function cambiarWorkspace(id, cambios) {
        const nuevo = [];
        for (let i = 0; i < estado.workspaces.length; i++) {
            const copia = Object.assign({}, estado.workspaces[i]);
            if (copia.id === id) {
                for (const clave in cambios)
                    copia[clave] = cambios[clave];
            }
            nuevo.push(copia);
        }
        estado.workspaces = nuevo;
    }

    property Process eventosNiri: Process {
        command: ["niri", "msg", "--json", "event-stream"]
        stdout: SplitParser {
            onRead: linea => estado.procesarEventoNiri(linea)
        }
        onExited: estado.reintentarNiri.start()
    }

    property Timer reintentarNiri: Timer {
        interval: 1000
        repeat: false
        onTriggered: estado.eventosNiri.running = true
    }

    Component.onCompleted: {
        estado.eventosNiri.running = true;
        estado.descubrirBrillo.running = true;
        estado.sondeoRed.trigger();
        estado.refrescarBrillo();
    }

    // --- Actualizaciones de NixOS ------------------------------------------

    property string updatesTexto: ""
    property string updatesAlt: "unknown"
    property string updatesTooltip: "Sin datos de actualizaciones"

    function actualizarUpdates(texto) {
        let datos;
        try {
            datos = JSON.parse(texto);
        } catch (error) {
            estado.updatesAlt = "unknown";
            estado.updatesTexto = "?";
            estado.updatesTooltip = "No se pudo leer el estado de actualizaciones.";
            return;
        }
        estado.updatesAlt = datos.alt || "unknown";
        estado.updatesTexto = datos.text || "";
        estado.updatesTooltip = datos.tooltip || "";
    }

    property Poll sondeoUpdates: Poll {
        // `nixos-updates bar` entrega {text, alt, tooltip} ya calculado.
        comando: ["nixos-updates", "bar"]
        intervalo: 300000
        onTextoChanged: estado.actualizarUpdates(texto)
    }

    // El servicio de updates avisa aquí cuando termina, para que la barra no
    // espere el siguiente ciclo de 5 minutos.
    property IpcHandler ipcUpdates: IpcHandler {
        target: "barra"
        function refrescarUpdates(): void {
            estado.sondeoUpdates.trigger();
        }
    }

    // --- Brillo -------------------------------------------------------------

    property bool brilloVisible: false
    property string brilloTexto: ""
    property string brilloAlt: "unavailable"
    property string brilloTooltip: ""

    function actualizarBrillo(texto) {
        let datos;
        try {
            datos = JSON.parse(texto);
        } catch (error) {
            estado.brilloVisible = false;
            return;
        }
        estado.brilloAlt = datos.alt || "unavailable";
        estado.brilloTexto = datos.text || "";
        estado.brilloTooltip = datos.tooltip || "";
        estado.brilloVisible = estado.brilloAlt !== "unavailable" && estado.brilloTexto !== "";
    }

    // El estado vive en archivos: DDC/CI publica state.json y el panel interno
    // expone sysfs. FileView notifica cambios sin lanzar un comando por segundo.
    property string rutaEstadoDdc: (Quickshell.env("XDG_RUNTIME_DIR") || "") + "/ddc-brightness/state.json"
    property string rutaBrillo: ""
    property string rutaBrilloMax: ""

    function leerBrilloArchivos() {
        let porcentaje = -1;
        const ddc = estado.archivoDdc.text().trim();
        if (ddc !== "") {
            try {
                const datos = JSON.parse(ddc);
                if (datos.percentage !== undefined)
                    porcentaje = Number(datos.percentage);
            } catch (error) {
                porcentaje = -1;
            }
        }
        if ((!isFinite(porcentaje) || porcentaje < 0) && estado.rutaBrillo !== "") {
            const actual = Number(estado.archivoBrillo.text().trim());
            const maximo = Number(estado.archivoBrilloMax.text().trim());
            if (isFinite(actual) && isFinite(maximo) && maximo > 0)
                porcentaje = Math.round(actual * 100 / maximo);
        }
        if (!isFinite(porcentaje) || porcentaje < 0) {
            estado.sondeoBrillo.trigger();
            return;
        }
        estado.brilloAlt = porcentaje < 30 ? "low" : (porcentaje < 65 ? "medium" : "high");
        estado.brilloTexto = porcentaje + "%";
        estado.brilloTooltip = "Brillo del monitor: " + porcentaje + "%";
        estado.brilloVisible = true;
    }

    property FileView archivoDdc: FileView {
        path: estado.rutaEstadoDdc
        watchChanges: true
        printErrors: false
        onFileChanged: this.reload()
        onLoaded: estado.leerBrilloArchivos()
        onTextChanged: estado.leerBrilloArchivos()
    }

    property FileView archivoBrillo: FileView {
        path: estado.rutaBrillo
        watchChanges: true
        printErrors: false
        onFileChanged: this.reload()
        onLoaded: estado.leerBrilloArchivos()
        onTextChanged: estado.leerBrilloArchivos()
    }

    property FileView archivoBrilloMax: FileView {
        path: estado.rutaBrilloMax
        watchChanges: true
        printErrors: false
        onFileChanged: this.reload()
        onLoaded: estado.leerBrilloArchivos()
        onTextChanged: estado.leerBrilloArchivos()
    }

    property Process descubrirBrillo: Process {
        command: ["sh", "-c", "ls /sys/class/backlight/*/brightness 2>/dev/null | head -1"]
        stdout: StdioCollector {
            onStreamFinished: {
                const ruta = text.trim();
                estado.rutaBrillo = ruta;
                estado.rutaBrilloMax = ruta.replace(/brightness$/, "max_brightness");
            }
        }
    }

    // Fallback para hosts sin archivos observables y refresco inmediato tras
    // una acción de rueda; no tiene temporizador.
    property Poll sondeoBrillo: Poll {
        comando: ["sh", "-c", estado.comandoBrillo + " json"]
        intervalo: 0
        onTextoChanged: estado.actualizarBrillo(texto)
    }

    function refrescarBrillo() {
        estado.sondeoBrillo.trigger();
    }

    // --- Audio (servicio nativo de PipeWire) -------------------------------

    readonly property var salida: Pipewire.defaultAudioSink
    readonly property var entrada: Pipewire.defaultAudioSource

    // Sin este tracker las propiedades de los nodos no notifican cambios.
    property PwObjectTracker trackerAudio: PwObjectTracker {
        objects: [Pipewire.defaultAudioSink, Pipewire.defaultAudioSource]
    }

    function volumenDe(nodo) {
        if (nodo === null || nodo.audio === null)
            return 0;
        return Math.round(nodo.audio.volume * 100);
    }

    function silenciadoDe(nodo) {
        return nodo !== null && nodo.audio !== null && nodo.audio.muted;
    }

    function descripcionDe(nodo) {
        if (nodo === null)
            return "";
        return nodo.description || nodo.name || "";
    }

    function ajustarVolumen(nodo, delta) {
        if (nodo === null || nodo.audio === null)
            return;
        nodo.audio.volume = Math.max(0, Math.min(1, nodo.audio.volume + delta));
    }

    function alternarSilencio(nodo) {
        if (nodo === null || nodo.audio === null)
            return;
        nodo.audio.muted = !nodo.audio.muted;
    }

    function alternarSalida() { estado.alternarSilencio(estado.salida); }
    function alternarEntrada() { estado.alternarSilencio(estado.entrada); }
    function subirSalida() { estado.ajustarVolumen(estado.salida, 0.02); }
    function bajarSalida() { estado.ajustarVolumen(estado.salida, -0.02); }
    function subirEntrada() { estado.ajustarVolumen(estado.entrada, 0.02); }
    function bajarEntrada() { estado.ajustarVolumen(estado.entrada, -0.02); }

    readonly property int volumenSalida: estado.volumenDe(estado.salida)
    readonly property bool salidaSilenciada: estado.silenciadoDe(estado.salida)
    readonly property string salidaDescripcion: estado.descripcionDe(estado.salida)
    readonly property int volumenEntrada: estado.volumenDe(estado.entrada)
    readonly property bool entradaSilenciada: estado.silenciadoDe(estado.entrada)

    // --- Red (NetworkManager con nmcli) ------------------------------------

    property string redTipo: "none"
    property string redNombre: ""
    property string redIp: ""
    property int redSenal: 0
    property string redTooltip: "Desconectado"

    function senalWifi(dispositivo, lineas) {
        // /proc/net/wireless: "wlp5s0: 0000  45.  -55.  -256 ..." donde el
        // tercer campo es la calidad sobre 70.
        for (const linea of lineas) {
            const campos = linea.trim().split(/\s+/);
            if (campos.length < 3 || campos[0] !== dispositivo + ":")
                continue;
            const calidad = parseFloat(campos[2]);
            if (!isFinite(calidad))
                continue;
            return Math.max(0, Math.min(100, Math.round(calidad * 100 / 70)));
        }
        return 0;
    }

    function actualizarRed(texto) {
        const lineas = texto.split("\n");
        const corte = lineas.indexOf("--inalambrico--");
        const dispositivos = corte >= 0 ? lineas.slice(0, corte) : lineas;
        const inalambrico = corte >= 0 ? lineas.slice(corte + 1) : [];

        let lista = [];
        let actual = null;
        for (const linea of dispositivos) {
            if (linea.trim() === "") {
                actual = null;
                continue;
            }
            const posicion = linea.indexOf(":");
            if (posicion <= 0)
                continue;
            const clave = linea.slice(0, posicion);
            const valor = linea.slice(posicion + 1).replace(/\\:/g, ":");
            if (clave === "GENERAL.DEVICE") {
                actual = {
                    dispositivo: valor,
                    tipo: "",
                    conectado: false,
                    conexion: "",
                    ip: "",
                    puerta: ""
                };
                lista.push(actual);
                continue;
            }
            if (actual === null)
                continue;
            if (clave === "GENERAL.TYPE") {
                actual.tipo = valor;
            } else if (clave === "GENERAL.STATE") {
                actual.conectado = valor.indexOf("100") === 0;
            } else if (clave === "GENERAL.CONNECTION") {
                actual.conexion = valor;
            } else if (clave.indexOf("IP4.ADDRESS") === 0 && actual.ip === "") {
                actual.ip = valor.split("/")[0];
            } else if (clave === "IP4.GATEWAY" && actual.puerta === "") {
                actual.puerta = valor;
            }
        }

        // Se anuncia el enlace principal: cable primero, luego wifi. Túneles,
        // puentes y loopback (Tailscale, docker) no son la conexión del usuario.
        let elegido = null;
        for (const candidato of lista) {
            if (candidato.conectado && candidato.tipo === "ethernet") {
                elegido = candidato;
                break;
            }
        }
        if (elegido === null) {
            for (const candidato of lista) {
                if (candidato.conectado && candidato.tipo === "wifi") {
                    elegido = candidato;
                    break;
                }
            }
        }

        if (elegido === null) {
            estado.redTipo = "none";
            estado.redNombre = "";
            estado.redIp = "";
            estado.redSenal = 0;
            estado.redTooltip = "Desconectado";
            return;
        }

        estado.redTipo = elegido.tipo;
        estado.redNombre = elegido.conexion;
        estado.redIp = elegido.ip;
        // El nombre del perfil de NetworkManager ("Conexión cableada 1")
        // confunde en el tooltip: se muestra el tipo de enlace y sus datos.
        const detalle = [
            "Interfaz: " + elegido.dispositivo,
            "IP: " + (elegido.ip !== "" ? elegido.ip : "—")
        ];
        if (elegido.puerta !== "")
            detalle.push("Puerta: " + elegido.puerta);
        if (elegido.tipo === "wifi") {
            estado.redSenal = estado.senalWifi(elegido.dispositivo, inalambrico);
            estado.redTooltip = (elegido.conexion !== "" ? elegido.conexion : "Wi-Fi")
                + " (" + estado.redSenal + "%)\n" + detalle.join("\n");
        } else {
            estado.redSenal = 100;
            estado.redTooltip = "Conexión cableada\n" + detalle.join("\n");
        }
    }

    // Networking notifica los cambios de enlace; el comando de IP solo se
    // ejecuta cuando cambia la conexión, no cada 3 segundos.
    function claveRed() {
        const partes = [];
        for (const dispositivo of Networking.devices.values) {
            if (!dispositivo.connected)
                continue;
            let nombre = "";
            for (const red of dispositivo.networks.values) {
                if (red.connected)
                    nombre = red.name || "";
            }
            partes.push(dispositivo.name + ":" + nombre);
        }
        return partes.join(",");
    }

    property string redClave: estado.claveRed()
    onRedClaveChanged: estado.sondeoRed.trigger()

    property Poll sondeoRed: Poll {
        comando: [
            "sh", "-c",
            "nmcli -t -f GENERAL.DEVICE,GENERAL.TYPE,GENERAL.STATE,GENERAL.CONNECTION,IP4.ADDRESS,IP4.GATEWAY device show; " +
            "echo --inalambrico--; " +
            "cat /proc/net/wireless 2>/dev/null"
        ]
        intervalo: 0
        onTextoChanged: estado.actualizarRed(texto)
    }

    // --- CPU ---------------------------------------------------------------

    property int cpuUso: 0
    property real cpuTotalAnterior: 0
    property real cpuOciosoAnterior: 0

    function actualizarCpu(texto) {
        // /proc/stat: cpu user nice system idle iowait irq softirq steal
        const campos = texto.trim().split(/\s+/);
        if (campos.length < 6 || campos[0] !== "cpu")
            return;
        const valores = campos.slice(1, 9).map(Number);
        let total = 0;
        for (const valor of valores)
            total += valor;
        const ocioso = valores[3] + (valores[4] || 0);

        if (estado.cpuTotalAnterior > 0 && total > estado.cpuTotalAnterior) {
            const deltaTotal = total - estado.cpuTotalAnterior;
            const deltaOcioso = ocioso - estado.cpuOciosoAnterior;
            estado.cpuUso = Math.max(0, Math.min(100, Math.round(100 * (1 - deltaOcioso / deltaTotal))));
        }
        estado.cpuTotalAnterior = total;
        estado.cpuOciosoAnterior = ocioso;
    }

    // --- Memoria -----------------------------------------------------------

    property real memoriaTotal: 0
    property real memoriaUsada: 0

    function actualizarMemoria(texto) {
        // `free -b`: total, used, free, shared, buff/cache, available.
        const campos = texto.trim().split(/\s+/);
        if (campos.length < 3)
            return;
        const total = Number(campos[1]);
        const disponible = campos.length >= 7 ? Number(campos[6]) : Number(campos[2]);
        if (!isFinite(total) || total <= 0)
            return;
        estado.memoriaTotal = total / 1073741824;
        estado.memoriaUsada = (total - disponible) / 1073741824;
    }

    function actualizarMetricas(texto) {
        const lineas = texto.trim().split("\n");
        if (lineas.length >= 1)
            estado.actualizarCpu(lineas[0].replace(/^cpu\s+/, "cpu "));
        if (lineas.length >= 2)
            estado.actualizarMemoria(lineas[1]);
    }

    // CPU y memoria comparten un solo proceso cada 5 s: son valores informativos,
    // no interactivos, y dos sondeos separados costaban dos execves cada 2 s.
    property Poll sondeoMetricas: Poll {
        comando: ["sh", "-c", "grep '^cpu ' /proc/stat; free -b | sed -n 2p"]
        intervalo: 5000
        onTextoChanged: estado.actualizarMetricas(texto)
    }

    // --- Batería -----------------------------------------------------------

    property bool bateriaPresente: false
    property int bateriaCarga: 0
    property string bateriaEstado: ""

    function actualizarBateria(texto) {
        const lineas = texto.trim().split("\n");
        if (lineas.length < 2) {
            estado.bateriaPresente = false;
            return;
        }
        const carga = parseInt(lineas[0], 10);
        if (!isFinite(carga)) {
            estado.bateriaPresente = false;
            return;
        }
        estado.bateriaPresente = true;
        estado.bateriaCarga = carga;
        estado.bateriaEstado = lineas[1].trim();
    }

    property Poll sondeoBateria: Poll {
        // Sin BAT0 (un escritorio) el comando falla y el módulo queda oculto.
        comando: ["sh", "-c", "cat /sys/class/power_supply/BAT0/capacity /sys/class/power_supply/BAT0/status"]
        intervalo: 10000
        onTextoChanged: estado.actualizarBateria(texto)
    }

    // --- Inhibidor de inactividad -----------------------------------------

    property bool inhibidorActivo: false

    function alternarInhibidor() {
        estado.inhibidorActivo = !estado.inhibidorActivo;
    }

    property Process inhibidor: Process {
        // Igual que el idle_inhibitor anterior: el bloqueo vive mientras el
        // proceso esté corriendo; apagarlo le manda SIGTERM.
        command: ["systemd-inhibit", "--what=idle", "--why=BarraLoon", "sleep", "infinity"]
        running: estado.inhibidorActivo
    }

    // --- Acciones ----------------------------------------------------------

    property Accion accionLanzador: Accion {
        comando: ["loon-launch"]
    }
    property Accion accionTerminal: Accion {
        comando: ["ghostty"]
    }
    property Accion accionMonitor: Accion {
        comando: ["ghostty", "-e", "btop"]
    }
    property Accion accionComprobarUpdates: Accion {
        comando: ["systemctl", "--user", "start", "--no-block", "nixos-updates-check.service"]
    }
    property Accion accionBrilloArriba: Accion {
        comando: ["sh", "-c", estado.comandoBrillo + " up 5"]
    }
    property Accion accionBrilloAbajo: Accion {
        comando: ["sh", "-c", estado.comandoBrillo + " down 5"]
    }
}
