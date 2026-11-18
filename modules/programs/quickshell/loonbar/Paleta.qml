import QtQuick
import Quickshell
import Quickshell.Io

// Paleta y tipografía de la barra.
//
// Los colores salen de ~/.config/loon-shell/colors.css y accent.css, que escribe
// `accent-wallpaper` con el color del wallpaper animado. FileView observa ambos
// archivos y el generador avisa además por IPC: la barra sigue el acento sin
// reiniciar el servicio de Quickshell ni depender de un sondeo periódico.
//
// Los valores por defecto son los mismos que siembra el módulo NixOS en esos
// archivos, para que la barra se vea bien antes del primer rebuild.
QtObject {
    id: paleta

    readonly property string home: Quickshell.env("HOME")
    readonly property string rutaColors: paleta.home + "/.config/loon-shell/colors.css"
    readonly property string rutaAccent: paleta.home + "/.config/loon-shell/accent.css"

    // Tipografía común: Nerd Font para los glifos de los módulos.
    readonly property string familia: "JetBrainsMono Nerd Font"
    readonly property int tamanoTexto: 14
    readonly property int tamanoIcono: 17

    property color background: "#11181A"
    property color backgroundAlt: "#1B2629"
    property color surface: "#1B2629"
    property color foreground: "#F0EDE1"
    property color accent: "#AB9A5E"
    // El nombre CSS es `on_accent`; en QML no puede empezar por "on" porque
    // se interpretaría como manejador de señal.
    property color sobreAcento: "#000000"
    property color highlight: "#7679C6"
    property color muted: "#8C8877"
    property color warning: "#E6A545"
    property color critical: "#E6506B"

    // Transición suave cuando cambia el fondo: cada color se interpola desde
    // su valor anterior, no salta al instante en que se publica la paleta.
    readonly property int duracionTransicion: 450

    Behavior on background {
        ColorAnimation { duration: paleta.duracionTransicion; easing.type: Easing.InOutQuad }
    }
    Behavior on backgroundAlt {
        ColorAnimation { duration: paleta.duracionTransicion; easing.type: Easing.InOutQuad }
    }
    Behavior on surface {
        ColorAnimation { duration: paleta.duracionTransicion; easing.type: Easing.InOutQuad }
    }
    Behavior on foreground {
        ColorAnimation { duration: paleta.duracionTransicion; easing.type: Easing.InOutQuad }
    }
    Behavior on accent {
        ColorAnimation { duration: paleta.duracionTransicion; easing.type: Easing.InOutQuad }
    }
    Behavior on sobreAcento {
        ColorAnimation { duration: paleta.duracionTransicion; easing.type: Easing.InOutQuad }
    }
    Behavior on highlight {
        ColorAnimation { duration: paleta.duracionTransicion; easing.type: Easing.InOutQuad }
    }
    Behavior on muted {
        ColorAnimation { duration: paleta.duracionTransicion; easing.type: Easing.InOutQuad }
    }
    Behavior on warning {
        ColorAnimation { duration: paleta.duracionTransicion; easing.type: Easing.InOutQuad }
    }
    Behavior on critical {
        ColorAnimation { duration: paleta.duracionTransicion; easing.type: Easing.InOutQuad }
    }

    // El generador de la paleta avisa aquí tras publicar los archivos, para
    // que el cambio llegue aunque FileView no detecte el reemplazo atómico.
    property IpcHandler ipcPaleta: IpcHandler {
        target: "paleta"
        function recargar(): void {
            paleta.archivoColores.reload();
            paleta.archivoAcento.reload();
        }
    }

    // Mismo efecto que `alpha(@color, 0.88)` de la hoja de estilos anterior.
    function alfa(color, opacidad) {
        return Qt.rgba(color.r, color.g, color.b, opacidad);
    }

    function asignar(nombre, valor) {
        switch (nombre) {
        case "background":
            paleta.background = valor;
            break;
        case "background_alt":
            paleta.backgroundAlt = valor;
            break;
        case "surface":
            paleta.surface = valor;
            break;
        case "foreground":
            paleta.foreground = valor;
            break;
        case "accent":
            paleta.accent = valor;
            break;
        case "on_accent":
            paleta.sobreAcento = valor;
            break;
        case "highlight":
            paleta.highlight = valor;
            break;
        case "muted":
            paleta.muted = valor;
            break;
        case "warning":
            paleta.warning = valor;
            break;
        case "critical":
            paleta.critical = valor;
            break;
        }
        // El resto de @define-color (color0..color15, transparent) no lo usa la
        // barra y se ignora a propósito.
    }

    // Parsea las definiciones CSS. accent.css va después, así que su acento pisa
    // al de colors.css, igual que con el @import anterior.
    function aplicar(texto) {
        const definicion = /@define-color\s+([\w-]+)\s+([^;]+);/g;
        let coincidencia;
        while ((coincidencia = definicion.exec(texto)) !== null) {
            const nombre = coincidencia[1];
            const valor = coincidencia[2].trim();
            if (valor !== "")
                paleta.asignar(nombre, valor);
        }
    }

    function sincronizar() {
        const colores = paleta.archivoColores.text();
        if (colores !== "")
            paleta.aplicar(colores);
        const acento = paleta.archivoAcento.text();
        if (acento !== "")
            paleta.aplicar(acento);
    }

    property FileView archivoColores: FileView {
        path: paleta.rutaColors
        watchChanges: true
        printErrors: false
        onFileChanged: this.reload()
        onLoaded: paleta.sincronizar()
        onTextChanged: paleta.sincronizar()
    }

    property FileView archivoAcento: FileView {
        path: paleta.rutaAccent
        watchChanges: true
        printErrors: false
        onFileChanged: this.reload()
        onLoaded: paleta.sincronizar()
        onTextChanged: paleta.sincronizar()
    }
}
