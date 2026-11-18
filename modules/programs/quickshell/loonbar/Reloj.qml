pragma ComponentBehavior: Bound
import QtQuick

// Reloj de la barra con fecha completa y calendario en el globo de ayuda.
//
// El reloj anterior mostraba solo la hora y, al pasar el ratón, el mes en curso;
// ahora la barra muestra también «día mes año». La rueda y el clic derecho
// siguen moviendo el calendario del globo y volviendo al mes actual.
Item {
    id: reloj

    property var estado: null
    property var paleta: null
    property int desfaseMes: 0

    readonly property var fecha: reloj.estado ? reloj.estado.ahora : new Date()
    readonly property var meses: ["enero", "febrero", "marzo", "abril", "mayo", "junio",
        "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"]
    readonly property var diasSemana: ["L", "M", "X", "J", "V", "S", "D"]

    readonly property string tituloMes: reloj.tituloCalendario()
    readonly property var celdas: reloj.celdasCalendario()
    readonly property string textoFecha: reloj.fecha.getDate() + " "
        + reloj.meses[reloj.fecha.getMonth()] + " "
        + reloj.fecha.getFullYear()

    width: fila.implicitWidth + 12
    height: 44

    // Número de semana ISO-8601, igual que el calendario que había antes.
    function semanaIso(fecha) {
        const copia = new Date(Date.UTC(fecha.getFullYear(), fecha.getMonth(), fecha.getDate()));
        const dia = copia.getUTCDay() || 7;
        copia.setUTCDate(copia.getUTCDate() + 4 - dia);
        const inicioAnio = new Date(Date.UTC(copia.getUTCFullYear(), 0, 1));
        return Math.ceil(((copia - inicioAnio) / 86400000 + 1) / 7);
    }

    function tituloCalendario() {
        const hoy = new Date();
        const base = new Date(hoy.getFullYear(), hoy.getMonth() + reloj.desfaseMes, 1);
        return reloj.meses[base.getMonth()] + " de " + base.getFullYear();
    }

    // Cada entrada es una celda real del calendario: el día de hoy se marca
    // con `hoy: true` y el delegado le pone el fondo del acento, en vez del
    // asterisco que se usaba cuando el globo era solo texto monospace.
    function celdasCalendario() {
        const hoy = new Date();
        const base = new Date(hoy.getFullYear(), hoy.getMonth() + reloj.desfaseMes, 1);
        const anio = base.getFullYear();
        const mes = base.getMonth();
        const diasEnMes = new Date(anio, mes + 1, 0).getDate();
        const esMesActual = hoy.getFullYear() === anio && hoy.getMonth() === mes;

        // La semana empieza en lunes (norma ISO), como el calendario anterior.
        const columnaInicial = (base.getDay() + 6) % 7;
        const dias = [];
        for (let i = 0; i < columnaInicial; i++)
            dias.push(null);
        for (let dia = 1; dia <= diasEnMes; dia++)
            dias.push({ numero: dia, hoy: esMesActual && hoy.getDate() === dia });
        while (dias.length % 7 !== 0)
            dias.push(null);

        const celdas = [];
        for (const dia of reloj.diasSemana)
            celdas.push({ texto: dia, tipo: "encabezado", hoy: false });
        celdas.push({ texto: "Sem", tipo: "encabezado", hoy: false });

        for (let i = 0; i < dias.length; i += 7) {
            const diaDeFila = Math.max(1, i - columnaInicial + 1);
            const semana = reloj.semanaIso(new Date(anio, mes, diaDeFila));
            for (let columna = 0; columna < 7; columna++) {
                const dia = dias[i + columna];
                celdas.push(dia
                    ? { texto: String(dia.numero), tipo: "dia", hoy: dia.hoy }
                    : { texto: "", tipo: "vacio", hoy: false });
            }
            celdas.push({ texto: String(semana), tipo: "semana", hoy: false });
        }
        return celdas;
    }

    readonly property Component calendarioVisual: Component {
        Item {
            id: calendario

            readonly property int anchoCelda: 30
            readonly property int altoCelda: 28

            width: calendario.anchoCelda * 8
            height: etiquetaMes.implicitHeight + 8 + Math.ceil(reloj.celdas.length / 8) * calendario.altoCelda

            Column {
                anchors.fill: parent
                spacing: 4

                Text {
                    id: etiquetaMes
                    text: reloj.tituloMes
                    color: reloj.paleta ? reloj.paleta.foreground : "#F0EDE1"
                    opacity: 0.85
                    font.family: reloj.paleta ? reloj.paleta.familia : "monospace"
                    font.pixelSize: 14
                    font.weight: Font.Medium
                }

                Grid {
                    columns: 8
                    rows: Math.ceil(reloj.celdas.length / 8)
                    columnSpacing: 0
                    rowSpacing: 0

                    Repeater {
                        model: reloj.celdas

                        delegate: Item {
                            id: celda
                            required property var modelData

                            width: calendario.anchoCelda
                            height: calendario.altoCelda

                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 2
                                radius: 7
                                color: reloj.paleta ? reloj.paleta.accent : "#AB9A5E"
                                visible: celda.modelData.hoy
                            }

                            Text {
                                anchors.centerIn: parent
                                text: celda.modelData.texto
                                color: {
                                    if (celda.modelData.hoy && reloj.paleta)
                                        return reloj.paleta.sobreAcento;
                                    if (reloj.paleta && (celda.modelData.tipo === "encabezado" || celda.modelData.tipo === "semana"))
                                        return reloj.paleta.muted;
                                    return reloj.paleta ? reloj.paleta.foreground : "#F0EDE1";
                                }
                                font.family: reloj.paleta ? reloj.paleta.familia : "monospace"
                                font.pixelSize: celda.modelData.tipo === "encabezado" ? 12 : 14
                                font.weight: celda.modelData.hoy ? Font.Bold : Font.Medium
                            }
                        }
                    }
                }
            }
        }
    }

    Row {
        id: fila
        anchors.centerIn: parent
        spacing: 8

        Text {
            id: etiqueta
            text: Qt.formatTime(reloj.fecha, "hh:mm AP")
            color: reloj.paleta ? reloj.paleta.foreground : "#F0EDE1"
            font.family: reloj.paleta ? reloj.paleta.familia : "monospace"
            font.pixelSize: reloj.paleta ? reloj.paleta.tamanoTexto : 13
            font.weight: Font.Bold
        }

        Text {
            text: reloj.textoFecha
            color: reloj.paleta ? reloj.paleta.muted : "#8C8877"
            font.family: reloj.paleta ? reloj.paleta.familia : "monospace"
            font.pixelSize: reloj.paleta ? reloj.paleta.tamanoTexto : 13
            font.weight: Font.Medium
        }
    }

    MouseArea {
        id: raton
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        hoverEnabled: true

        onClicked: reloj.desfaseMes = 0;

        onWheel: evento => {
            if (evento.angleDelta.y > 0)
                reloj.desfaseMes -= 1;
            else if (evento.angleDelta.y < 0)
                reloj.desfaseMes += 1;
        }
    }

    Tooltip {
        objetivo: reloj
        contenido: reloj.calendarioVisual
        mostrar: raton.containsMouse
        paleta: reloj.paleta
    }
}
