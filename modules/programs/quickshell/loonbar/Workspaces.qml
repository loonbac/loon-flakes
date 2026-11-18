import QtQuick

// Workspaces de niri: la celda activa actúa como Dynamic Island cuando hay
// multimedia en reproducción, ensanchándose suavemente para mostrar un
// micro-ecualizador y el título en reproducción.
Row {
    id: workspaces

    property var estado: null
    property var paleta: null
    property var reproductor: null
    property string salida: ""

    spacing: 3
    height: 32

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

    Repeater {
        model: workspaces.lista()

        delegate: Rectangle {
            id: celda
            required property var modelData

            readonly property bool estaEnfocado: celda.modelData.is_focused
            readonly property bool islaActiva: celda.estaEnfocado
                && workspaces.reproductor !== null
                && workspaces.reproductor.isPlaying

            readonly property int anchoBase: Math.max(42, etiqueta.implicitWidth + 20)
            readonly property int anchoIsla: anchoBase + contenidoIsla.implicitWidth + 12

            width: celda.islaActiva ? anchoIsla : anchoBase
            height: 32
            radius: 7
            clip: true
            color: workspaces.colorFondo(celda.modelData)

            Behavior on width {
                NumberAnimation {
                    duration: 300
                    easing.type: Easing.OutBack
                    easing.overshoot: 1.08
                }
            }

            Row {
                anchors.centerIn: parent
                spacing: 6

                Text {
                    id: etiqueta
                    anchors.verticalCenter: parent.verticalCenter
                    text: celda.modelData.name !== null ? String(celda.modelData.name) : String(celda.modelData.idx)
                    color: workspaces.colorTexto(celda.modelData)
                    font.family: workspaces.paleta ? workspaces.paleta.familia : "monospace"
                    font.pixelSize: workspaces.paleta ? workspaces.paleta.tamanoTexto : 13
                    font.weight: Font.Bold
                }

                Row {
                    id: contenidoIsla
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    visible: celda.islaActiva
                    opacity: celda.islaActiva ? 1.0 : 0.0

                    Behavior on opacity {
                        NumberAnimation { duration: 180 }
                    }

                    // Ecualizador de 3 barras con alturas animadas
                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        Rectangle {
                            width: 2
                            height: 10
                            radius: 1
                            color: workspaces.paleta ? workspaces.paleta.sobreAcento : "#111111"

                            SequentialAnimation on height {
                                running: celda.islaActiva
                                loops: Animation.Infinite
                                NumberAnimation { to: 4; duration: 280; easing.type: Easing.InOutQuad }
                                NumberAnimation { to: 12; duration: 320; easing.type: Easing.InOutQuad }
                                NumberAnimation { to: 7; duration: 220; easing.type: Easing.InOutQuad }
                            }
                        }

                        Rectangle {
                            width: 2
                            height: 6
                            radius: 1
                            color: workspaces.paleta ? workspaces.paleta.sobreAcento : "#111111"

                            SequentialAnimation on height {
                                running: celda.islaActiva
                                loops: Animation.Infinite
                                NumberAnimation { to: 13; duration: 240; easing.type: Easing.InOutQuad }
                                NumberAnimation { to: 5; duration: 300; easing.type: Easing.InOutQuad }
                                NumberAnimation { to: 11; duration: 260; easing.type: Easing.InOutQuad }
                            }
                        }

                        Rectangle {
                            width: 2
                            height: 8
                            radius: 1
                            color: workspaces.paleta ? workspaces.paleta.sobreAcento : "#111111"

                            SequentialAnimation on height {
                                running: celda.islaActiva
                                loops: Animation.Infinite
                                NumberAnimation { to: 12; duration: 340; easing.type: Easing.InOutQuad }
                                NumberAnimation { to: 4; duration: 200; easing.type: Easing.InOutQuad }
                                NumberAnimation { to: 9; duration: 280; easing.type: Easing.InOutQuad }
                            }
                        }
                    }

                    Text {
                        id: tituloPista
                        anchors.verticalCenter: parent.verticalCenter
                        text: workspaces.reproductor && workspaces.reproductor.trackTitle
                            ? String(workspaces.reproductor.trackTitle)
                            : ""
                        color: workspaces.paleta ? workspaces.paleta.sobreAcento : "#111111"
                        font.family: workspaces.paleta ? workspaces.paleta.familia : "monospace"
                        font.pixelSize: (workspaces.paleta ? workspaces.paleta.tamanoTexto : 13) - 1
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                        width: Math.min(implicitWidth, 140)
                    }
                }
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
