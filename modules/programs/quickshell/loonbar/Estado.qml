import QtQuick
import Quickshell.Io

// Estado compartido por todas las barras (una por monitor).
//
// Cada dato se consulta una sola vez aunque haya varias pantallas: aquí viven
// los sondeos y las acciones, y `Barra.qml` solo los presenta. Todo se obtiene
// de comandos del sistema, salvo lo que Quickshell ya trae como servicio
// (trayectoria, bandeja y Bluetooth se leen en `Barra.qml` desde sus módulos).
QtObject {
    id: estado

    // --- Reloj -------------------------------------------------------------

    // Objeto Date de ahora mismo; se refresca cada segundo (el reloj solo
    // muestra minutos, pero el tooltip y el calendario salen de aquí).
    property date ahora: new Date()

    property Timer latidoReloj: Timer {
        interval: 1000
        repeat: true
        running: true
        onTriggered: estado.ahora = new Date()
    }

    // --- Workspaces de niri -------------------------------------------------

    // No hay plugin QML de niri, así que se consulta su IPC por CLI.
    property var workspaces: []
    // Último JSON leído: si no cambió no se reparsea, para no reconstruir los
    // botones de workspace cada 1,5 s (parpadeo).
    property string workspacesCrudo: ""

    property Poll sondeoWorkspaces: Poll {
        comando: ["niri", "msg", "--json", "workspaces"]
        intervalo: 1500
        onTextoChanged: {
            const crudo = estado.sondeoWorkspaces.texto;
            if (crudo === estado.workspacesCrudo)
                return;
            estado.workspacesCrudo = crudo;
            if (crudo.trim() === "") {
                estado.workspaces = [];
                return;
            }
            try {
                estado.workspaces = JSON.parse(crudo);
            } catch (error) {
                // JSON incompleto o niri caído: se conserva lo último bueno.
            }
        }
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

    property Poll sondeoBrillo: Poll {
        // En un monitor externo sin /sys/class/backlight responde
        // alt "unavailable" y el módulo se oculta.
        comando: ["screen-brightness", "json"]
        intervalo: 1000
        onTextoChanged: estado.actualizarBrillo(texto)
    }

    function refrescarBrillo() {
        estado.sondeoBrillo.trigger();
    }

    // --- Audio (PipeWire con wpctl) ----------------------------------------

    property int volumenSalida: 0
    property bool salidaSilenciada: false
    property string salidaDescripcion: ""
    property int volumenEntrada: 0
    property bool entradaSilenciada: false

    function leerVolumen(lineas) {
        let volumen = 0;
        let silenciado = false;
        let descripcion = "";
        for (const linea of lineas) {
            const valor = /^Volume:\s*([\d.]+)/.exec(linea);
            if (valor) {
                volumen = Math.round(parseFloat(valor[1]) * 100);
                silenciado = linea.indexOf("[MUTED]") >= 0;
                continue;
            }
            const desc = /node\.description\s*=\s*"([^"]*)"/.exec(linea);
            if (desc)
                descripcion = desc[1];
        }
        return {
            volumen: volumen,
            silenciado: silenciado,
            descripcion: descripcion
        };
    }

    function actualizarAudio(texto) {
        const lineas = texto.split("\n");
        const separador = lineas.indexOf("--");
        const salida = estado.leerVolumen(separador >= 0 ? lineas.slice(0, separador) : lineas);
        const entrada = estado.leerVolumen(separador >= 0 ? lineas.slice(separador + 1) : []);

        estado.volumenSalida = salida.volumen;
        estado.salidaSilenciada = salida.silenciado;
        estado.salidaDescripcion = salida.descripcion;
        estado.volumenEntrada = entrada.volumen;
        estado.entradaSilenciada = entrada.silenciado;
    }

    property Poll sondeoAudio: Poll {
        comando: [
            "sh", "-c",
            "wpctl get-volume @DEFAULT_AUDIO_SINK@; " +
            "wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null | grep -m1 node.description; " +
            "echo --; " +
            "wpctl get-volume @DEFAULT_AUDIO_SOURCE@"
        ]
        intervalo: 1500
        onTextoChanged: estado.actualizarAudio(texto)
    }

    function refrescarAudio() {
        estado.sondeoAudio.trigger();
    }

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
                    ip: ""
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
        if (elegido.tipo === "wifi") {
            estado.redSenal = estado.senalWifi(elegido.dispositivo, inalambrico);
            estado.redTooltip = elegido.conexion + " (" + estado.redSenal + "%)\n" + elegido.ip;
        } else {
            estado.redSenal = 100;
            estado.redTooltip = elegido.conexion + "\n" + elegido.ip;
        }
    }

    property Poll sondeoRed: Poll {
        comando: [
            "sh", "-c",
            "nmcli -t -f GENERAL.DEVICE,GENERAL.TYPE,GENERAL.STATE,GENERAL.CONNECTION,IP4.ADDRESS device show; " +
            "echo --inalambrico--; " +
            "cat /proc/net/wireless 2>/dev/null"
        ]
        intervalo: 3000
        onTextoChanged: estado.actualizarRed(texto)
    }

    function refrescarRed() {
        estado.sondeoRed.trigger();
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

    property Poll sondeoCpu: Poll {
        comando: ["sh", "-c", "grep '^cpu ' /proc/stat"]
        intervalo: 2000
        onTextoChanged: estado.actualizarCpu(texto)
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

    property Poll sondeoMemoria: Poll {
        comando: ["sh", "-c", "free -b | sed -n 2p"]
        intervalo: 2000
        onTextoChanged: estado.actualizarMemoria(texto)
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
        intervalo: 5000
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
        comando: ["screen-brightness", "up", "5"]
    }
    property Accion accionBrilloAbajo: Accion {
        comando: ["screen-brightness", "down", "5"]
    }
    property Accion accionSilenciarSalida: Accion {
        comando: ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"]
    }
    property Accion accionSilenciarEntrada: Accion {
        comando: ["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"]
    }
    property Accion accionSalidaMas: Accion {
        comando: ["wpctl", "set-volume", "--limit", "1.0", "@DEFAULT_AUDIO_SINK@", "2%+"]
    }
    property Accion accionSalidaMenos: Accion {
        comando: ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "2%-"]
    }
    property Accion accionEntradaMas: Accion {
        comando: ["wpctl", "set-volume", "--limit", "1.0", "@DEFAULT_AUDIO_SOURCE@", "2%+"]
    }
    property Accion accionEntradaMenos: Accion {
        comando: ["wpctl", "set-volume", "@DEFAULT_AUDIO_SOURCE@", "2%-"]
    }
}
