import QtQuick

// Indicador circular que aparece a la derecha de la isla cuando cambia el
// volumen de salida. No es un botón: solo muestra el nivel con el color accent
// de la barra y se oculta solo. La entrada la mueve Barra.qml con anchors.
Item {
    id: indicador

    property var paleta: null
    property var estado: null

    readonly property real fraccion: estado
        ? Math.max(0, Math.min(100, estado.volumenSalida)) / 100
        : 0
    property int margen: -48

    width: 40
    height: 40
    visible: false
    opacity: 0
    transformOrigin: Item.Center

    readonly property bool totalmenteVisible: indicador.visible
        && indicador.opacity > 0.99
        && indicador.margen >= 9.5
        && !desaparecer.running

    transform: Scale {
        id: deformacion
        xScale: 1
        yScale: 1
    }

    // Las animaciones sólo fijan el valor final. Si el volumen cambia a mitad
    // de una animación, la siguiente arranca desde el valor actual: así no hay
    // saltos al bajar rápido ni peleas entre dos animaciones. Sólo se reproduce
    // la deformación al entrar o salir; una vez visible, mantenerse quieto.
    SequentialAnimation {
        id: aparecer
        ParallelAnimation {
            NumberAnimation {
                target: indicador
                property: "margen"
                to: 10
                duration: 220
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: indicador
                property: "opacity"
                to: 1
                duration: 170
                easing.type: Easing.OutQuad
            }
            NumberAnimation {
                target: deformacion
                property: "xScale"
                to: 1.14
                duration: 220
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: deformacion
                property: "yScale"
                to: 0.86
                duration: 220
                easing.type: Easing.OutCubic
            }
        }
        ParallelAnimation {
            NumberAnimation { target: deformacion; property: "xScale"; to: 0.96; duration: 140; easing.type: Easing.OutQuad }
            NumberAnimation { target: deformacion; property: "yScale"; to: 1.06; duration: 140; easing.type: Easing.OutQuad }
        }
        ParallelAnimation {
            NumberAnimation { target: deformacion; property: "xScale"; to: 1; duration: 260; easing.type: Easing.OutElastic; easing.amplitude: 1.1; easing.period: 0.4 }
            NumberAnimation { target: deformacion; property: "yScale"; to: 1; duration: 260; easing.type: Easing.OutElastic; easing.amplitude: 1.1; easing.period: 0.4 }
        }
    }

    SequentialAnimation {
        id: desaparecer
        ParallelAnimation {
            NumberAnimation { target: deformacion; property: "xScale"; to: 1.14; duration: 120; easing.type: Easing.OutQuad }
            NumberAnimation { target: deformacion; property: "yScale"; to: 0.88; duration: 120; easing.type: Easing.OutQuad }
        }
        ParallelAnimation {
            NumberAnimation {
                target: indicador
                property: "margen"
                to: -48
                duration: 320
                easing.type: Easing.InOutCubic
            }
            NumberAnimation {
                target: indicador
                property: "opacity"
                to: 0
                duration: 260
                easing.type: Easing.InQuad
            }
            NumberAnimation {
                target: deformacion
                property: "xScale"
                to: 0.74
                duration: 320
                easing.type: Easing.InOutBack
                easing.overshoot: 1.3
            }
            NumberAnimation {
                target: deformacion
                property: "yScale"
                to: 0.86
                duration: 320
                easing.type: Easing.InOutBack
                easing.overshoot: 1.3
            }
        }
        onFinished: indicador.visible = false
    }

    Timer {
        id: ocultar
        interval: 1400
        repeat: false
        onTriggered: {
            aparecer.stop();
            desaparecer.restart();
        }
    }

    Connections {
        target: indicador.estado
        function onVolumenSalidaChanged(): void { indicador.mostrar(); }
    }

    function mostrar() {
        desaparecer.stop();
        if (!indicador.visible) {
            indicador.margen = -48;
            indicador.opacity = 0;
            deformacion.xScale = 1;
            deformacion.yScale = 1;
            indicador.visible = true;
            aparecer.restart();
        } else if (!indicador.totalmenteVisible) {
            aparecer.restart();
        }
        // Si ya está totalmente visible, sólo actualiza el arco y el temporizador.
        ocultar.restart();
    }

    Rectangle {
        anchors.fill: parent
        radius: 20
        color: indicador.paleta
            ? indicador.paleta.alfa(indicador.paleta.background, 0.94)
            : "#F011181A"
        border.width: 1
        border.color: indicador.paleta
            ? indicador.paleta.alfa(indicador.paleta.foreground, 0.25)
            : "#40F0EDE1"
    }

    Canvas {
        id: arco
        anchors.fill: parent

        onPaint: {
            const ctx = arco.getContext("2d");
            if (!ctx)
                return;

            const centroX = arco.width / 2;
            const centroY = arco.height / 2;
            const radio = centroX - 5;
            const fondo = indicador.paleta
                ? indicador.paleta.alfa(indicador.paleta.foreground, 0.18)
                : "#59F0EDE1";
            const acento = indicador.paleta ? indicador.paleta.accent : "#AB9A5E";

            ctx.clearRect(0, 0, arco.width, arco.height);
            ctx.lineWidth = 4;
            ctx.lineCap = "round";

            ctx.strokeStyle = fondo.toString();
            ctx.beginPath();
            ctx.arc(centroX, centroY, radio, 0, Math.PI * 2);
            ctx.stroke();

            ctx.strokeStyle = acento.toString();
            ctx.beginPath();
            ctx.arc(
                centroX, centroY, radio,
                -Math.PI / 2,
                -Math.PI / 2 + Math.PI * 2 * indicador.fraccion
            );
            ctx.stroke();
        }

        Component.onCompleted: arco.requestPaint()
        onWidthChanged: arco.requestPaint()
        onHeightChanged: arco.requestPaint()
    }

    Connections {
        target: indicador
        function onFraccionChanged(): void { arco.requestPaint(); }
        function onPaletaChanged(): void { arco.requestPaint(); }
    }

    Text {
        anchors.centerIn: parent
        text: indicador.fraccion >= 0.34 ? "\uF028" : "\uF026"
        color: indicador.paleta ? indicador.paleta.foreground : "#F0EDE1"
        font.family: indicador.paleta ? indicador.paleta.familia : "monospace"
        font.pixelSize: 16
        font.weight: Font.DemiBold
    }
}
