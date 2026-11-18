import QtQuick

// Workspaces de niri y, debajo, la actividad multimedia del sistema.
//
// La card entera es la isla dinámica: en reposo muestra solo la fila de
// workspaces con la geometría aceptada (celdas de 32 px, radio 7, spacing 3).
// Mientras algo se reproduce y el ratón está encima (`expandida`), se añade una
// segunda fila con ecualizador, título y controles esenciales, y `Barra.qml`
// agranda la card completa: una sola superficie, sin morph de la celda activa ni
// ventana emergente aparte.
Column {
    id: workspaces

    property var estado: null
    property var paleta: null
    property var reproductor: null
    property string salida: ""
    // La fija `Barra.qml` con `barra.islaExpandida`: sin hover sobre la card la
    // fila multimedia no se muestra aunque haya reproducción (L5).
    property bool expandida: false

    readonly property bool reproduciendo: workspaces.reproductor !== null
        && workspaces.reproductor.isPlaying

    spacing: 4

    function lista() {
        const todas = workspaces.estado ? workspaces.estado.workspaces : [];
        const propias = [];
        for (const espacio of todas) {
            if (espacio.output === workspaces.salida)
                propias.push(espacio);
        }
        propias.sort((a, b) => a.idx - b.idx);
        return propias;
    }

    function colorFondo(espacio) {
        const paleta = workspaces.paleta;
        if (espacio.is_urgent && paleta)
            return paleta.warning;
        if (espacio.is_focused && paleta)
            return paleta.accent;
        if (paleta)
            return paleta.alfa(paleta.foreground, espacio.is_active ? 0.3 : 0.15);
        return "#33FFFFFF";
    }

    function colorTexto(espacio) {
        const paleta = workspaces.paleta;
        if (!paleta)
            return "#F0EDE1";
        return espacio.is_focused ? paleta.sobreAcento : paleta.foreground;
    }

    function colorPista() {
        return workspaces.paleta ? workspaces.paleta.foreground : "#F0EDE1";
    }

    function colorAcento() {
        return workspaces.paleta ? workspaces.paleta.accent : "#AB9A5E";
    }

    function puedeAnterior() {
        return workspaces.reproductor !== null && workspaces.reproductor.canGoPrevious;
    }

    function puedeSiguiente() {
        return workspaces.reproductor !== null && workspaces.reproductor.canGoNext;
    }

    function puedeAlternar() {
        return workspaces.reproductor !== null && workspaces.reproductor.canTogglePlaying;
    }

    // --- Fila de workspaces de niri (geometría aceptada) -------------------

    Row {
        id: filaWorkspaces

        spacing: 3
        height: 32

        Repeater {
            model: workspaces.lista()

            delegate: Rectangle {
                id: celda
                required property var modelData

                readonly property int anchoBase: Math.max(42, etiqueta.implicitWidth + 20)

                width: celda.anchoBase
                height: 32
                radius: 7
                color: workspaces.colorFondo(celda.modelData)

                Text {
                    id: etiqueta
                    anchors.centerIn: parent
                    text: celda.modelData.name !== null ? String(celda.modelData.name) : String(celda.modelData.idx)
                    color: workspaces.colorTexto(celda.modelData)
                    font.family: workspaces.paleta ? workspaces.paleta.familia : "monospace"
                    font.pixelSize: workspaces.paleta ? workspaces.paleta.tamanoTexto : 13
                    font.weight: Font.Bold
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: foco.ejecutar()
                }

                Accion {
                    id: foco
                    comando: ["niri", "msg", "action", "focus-workspace", String(celda.modelData.idx)]
                }
            }
        }
    }

    // --- Fila multimedia, dentro de la misma card --------------------------
    //
    // Solo existe mientras se reproduce y la isla está expandida por hover (S3,
    // L5); al desaparecer no deja hueco, así la card recupera su alto de reposo
    // sin transición de contenido.
    Row {
        id: filaMultimedia

        visible: workspaces.reproduciendo && workspaces.expandida
        height: 32
        spacing: 8

        // Ecualizador de tres barras: identidad de la isla mientras suena algo.
        Item {
            anchors.verticalCenter: parent.verticalCenter
            width: 14
            height: 32

            Rectangle {
                anchors.bottom: parent.bottom
                width: 3
                height: 10
                radius: 1.5
                color: workspaces.colorAcento()

                SequentialAnimation on height {
                    running: workspaces.reproduciendo
                    loops: Animation.Infinite
                    NumberAnimation { to: 5; duration: 280; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 16; duration: 320; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 9; duration: 220; easing.type: Easing.InOutQuad }
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                x: 5
                width: 3
                height: 18
                radius: 1.5
                color: workspaces.colorAcento()

                SequentialAnimation on height {
                    running: workspaces.reproduciendo
                    loops: Animation.Infinite
                    NumberAnimation { to: 20; duration: 240; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 7; duration: 300; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 14; duration: 260; easing.type: Easing.InOutQuad }
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                x: 10
                width: 3
                height: 13
                radius: 1.5
                color: workspaces.colorAcento()

                SequentialAnimation on height {
                    running: workspaces.reproduciendo
                    loops: Animation.Infinite
                    NumberAnimation { to: 16; duration: 340; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 6; duration: 200; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 11; duration: 280; easing.type: Easing.InOutQuad }
                }
            }
        }

        // Título de la pista: grande, pesado y recortado con elipsis (L3).
        Text {
            id: tituloPista

            anchors.verticalCenter: parent.verticalCenter
            readonly property string pista: workspaces.reproductor && workspaces.reproductor.trackTitle
                ? String(workspaces.reproductor.trackTitle)
                : ""
            text: tituloPista.pista !== "" ? tituloPista.pista : "Reproduciendo"
            width: Math.min(implicitWidth, 150)
            elide: Text.ElideRight
            color: workspaces.colorPista()
            font.family: workspaces.paleta ? workspaces.paleta.familia : "monospace"
            font.pixelSize: (workspaces.paleta ? workspaces.paleta.tamanoTexto : 14) - 1
            font.weight: Font.DemiBold
        }

        // Controles esenciales: anterior, alternar y siguiente.
        Item {
            anchors.verticalCenter: parent.verticalCenter
            width: 16
            height: 32

            Text {
                anchors.centerIn: parent
                text: "\u{F048}"
                color: workspaces.colorPista()
                opacity: workspaces.puedeAnterior() ? 0.95 : 0.3
                font.family: workspaces.paleta ? workspaces.paleta.familia : "monospace"
                font.pixelSize: 13
            }

            MouseArea {
                anchors.fill: parent
                enabled: workspaces.puedeAnterior()
                onClicked: workspaces.reproductor.previous()
            }
        }

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 24
            height: 24
            radius: 12
            color: workspaces.colorAcento()

            Text {
                anchors.centerIn: parent
                text: workspaces.reproduciendo ? "\u{F04C}" : "\u{F04B}"
                color: workspaces.paleta ? workspaces.paleta.sobreAcento : "#111111"
                font.family: workspaces.paleta ? workspaces.paleta.familia : "monospace"
                font.pixelSize: 12
            }

            MouseArea {
                anchors.fill: parent
                enabled: workspaces.puedeAlternar()
                onClicked: workspaces.reproductor.togglePlaying()
            }
        }

        Item {
            anchors.verticalCenter: parent.verticalCenter
            width: 16
            height: 32

            Text {
                anchors.centerIn: parent
                text: "\u{F051}"
                color: workspaces.colorPista()
                opacity: workspaces.puedeSiguiente() ? 0.95 : 0.3
                font.family: workspaces.paleta ? workspaces.paleta.familia : "monospace"
                font.pixelSize: 13
            }

            MouseArea {
                anchors.fill: parent
                enabled: workspaces.puedeSiguiente()
                onClicked: workspaces.reproductor.next()
            }
        }
    }
}
