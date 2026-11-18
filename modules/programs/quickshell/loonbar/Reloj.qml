import QtQuick

// Reloj de la barra con calendario en el globo de ayuda.
//
// El reloj anterior mostraba la hora y, al pasar el ratón, el mes en curso; la
// rueda y el clic derecho movían el calendario de mes, así que aquí se conserva
// lo mismo: la rueda cambia de mes y el clic vuelve al actual.
Item {
    id: reloj

    property var estado: null
    property var paleta: null
    property int desfaseMes: 0

    readonly property var fecha: reloj.estado ? reloj.estado.ahora : new Date()
    readonly property var meses: ["enero", "febrero", "marzo", "abril", "mayo", "junio",
        "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"]
    readonly property var diasSemana: ["L", "M", "X", "J", "V", "S", "D"]

    width: etiqueta.width + 12
    height: 44

    // Número de semana ISO-8601, igual que el calendario que había antes.
    function semanaIso(fecha) {
        const copia = new Date(Date.UTC(fecha.getFullYear(), fecha.getMonth(), fecha.getDate()));
        const dia = copia.getUTCDay() || 7;
        copia.setUTCDate(copia.getUTCDate() + 4 - dia);
        const inicioAnio = new Date(Date.UTC(copia.getUTCFullYear(), 0, 1));
        return Math.ceil(((copia - inicioAnio) / 86400000 + 1) / 7);
    }

    function calendario() {
        const hoy = new Date();
        const base = new Date(hoy.getFullYear(), hoy.getMonth() + reloj.desfaseMes, 1);
        const anio = base.getFullYear();
        const mes = base.getMonth();
        const diasEnMes = new Date(anio, mes + 1, 0).getDate();
        const esMesActual = hoy.getFullYear() === anio && hoy.getMonth() === mes;

        // La semana empieza en lunes (norma ISO), como el calendario anterior.
        const columnaInicial = (new Date(anio, mes, 1).getDay() + 6) % 7;

        const celdas = [];
        for (let i = 0; i < columnaInicial; i++)
            celdas.push("    ");
        for (let dia = 1; dia <= diasEnMes; dia++) {
            // Columna de 4 caracteres: dos de relleno, el día y un hueco que
            // ocupa el asterisco del día de hoy (sin pegarse al día siguiente).
            celdas.push(" " + String(dia).padStart(2, " ") + (esMesActual && hoy.getDate() === dia ? "*" : " "));
        }
        while (celdas.length % 7 !== 0)
            celdas.push("    ");

        const lineas = [];
        lineas.push(reloj.meses[mes] + " de " + anio);
        lineas.push("   " + reloj.diasSemana.map(dia => " " + dia + "  ").join("") + " Sem");
        for (let i = 0; i < celdas.length; i += 7) {
            const diaDeFila = Math.max(1, i - columnaInicial + 1);
            const semana = reloj.semanaIso(new Date(anio, mes, diaDeFila));
            lineas.push("   " + celdas.slice(i, i + 7).join("") + " " + String(semana).padStart(3, " "));
        }
        return lineas.join("\n");
    }

    Text {
        id: etiqueta
        anchors.centerIn: parent
        text: Qt.formatTime(reloj.fecha, "hh:mm AP")
        color: reloj.paleta ? reloj.paleta.foreground : "#F0EDE1"
        font.family: reloj.paleta ? reloj.paleta.familia : "monospace"
        font.pixelSize: reloj.paleta ? reloj.paleta.tamanoTexto : 13
        font.weight: Font.Bold
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
        texto: reloj.calendario()
        mostrar: raton.containsMouse
        paleta: reloj.paleta
    }
}
