import QtQuick

// Workspaces de niri y, debajo, la actividad multimedia del sistema.
//
// La card entera es la isla dinámica: en reposo muestra la fila de workspaces
// con la geometría aceptada (celdas de 32 px, radio 7, spacing 3) y un pequeño
// ecualizador en la celda activa cuando algo se reproduce (L8). Mientras el
// ratón está encima (`expandida`), se añaden dos
// filas: arriba el indicador de reproducción con artista y título, debajo los
// controles grandes centrados; `Barra.qml` agranda la card completa: una sola
// superficie, sin morph de la celda activa ni ventana emergente aparte.
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

        // La columna se ensancha al aparecer la fila multimedia; sin este
        // anclaje los workspaces quedarían alineados a la izquierda (L7).
        anchors.horizontalCenter: parent.horizontalCenter
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

                // Pista compacta en reposo: mientras algo suena, la celda
                // activa lleva un ecualizador en la esquina. Así se ve que la
                // isla tiene contenido sin ensanchar la card ni mover celdas.
                Rectangle {
                    anchors.top: parent.top
                    anchors.topMargin: 2
                    anchors.right: parent.right
                    anchors.rightMargin: 2
                    width: 16
                    height: 12
                    radius: 4
                    visible: celda.modelData.is_focused
                        && workspaces.reproduciendo
                        && !workspaces.expandida
                    color: workspaces.colorAcento()

                    Row {
                        anchors.centerIn: parent
                        spacing: 2

                        Repeater {
                            model: 3

                            Rectangle {
                                width: 2
                                height: 4
                                radius: 1
                                color: workspaces.paleta
                                    ? workspaces.paleta.sobreAcento
                                    : "#111111"

                                SequentialAnimation on height {
                                    running: workspaces.reproduciendo && !workspaces.expandida
                                    loops: Animation.Infinite
                                    NumberAnimation {
                                        to: 9
                                        duration: 180 + index * 60
                                        easing.type: Easing.InOutQuad
                                    }
                                    NumberAnimation {
                                        to: 3
                                        duration: 220 + index * 40
                                        easing.type: Easing.InOutQuad
                                    }
                                }
                            }
                        }
                    }
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
    // sin transición de contenido. Se apila en dos niveles (L6): arriba el
    // indicador de reproducción con artista y título, debajo los controles
    // grandes y centrados. El ancho es el de la fila de workspaces para que el
    // bloque quede centrado en la card sin ensancharla.
    Column {
        id: filaMultimedia

        visible: workspaces.reproduciendo && workspaces.expandida
        width: Math.max(186, filaWorkspaces.implicitWidth)
        spacing: 6

        // Nivel superior: indicador de reproducción, artista y título.
        Row {
            id: filaAhora

            anchors.horizontalCenter: parent.horizontalCenter
            height: 30
            spacing: 8

            // Cápsula con ecualizador de cinco barras: la señal visible de que
            // algo se está reproduciendo, como el indicador del iPhone (L6).
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 28
                height: 28
                radius: 9
                color: workspaces.paleta
                    ? workspaces.paleta.alfa(workspaces.colorAcento(), 0.18)
                    : "#33AB9A5E"
                border.width: 1
                border.color: workspaces.paleta
                    ? workspaces.paleta.alfa(workspaces.colorAcento(), 0.38)
                    : "#61AB9A5E"

                Item {
                    anchors.centerIn: parent
                    width: 18
                    height: 14

                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: 2
                        height: 6
                        radius: 1
                        color: workspaces.colorAcento()

                        SequentialAnimation on height {
                            running: workspaces.reproduciendo
                            loops: Animation.Infinite
                            NumberAnimation { to: 13; duration: 280; easing.type: Easing.InOutQuad }
                            NumberAnimation { to: 4; duration: 240; easing.type: Easing.InOutQuad }
                            NumberAnimation { to: 9; duration: 300; easing.type: Easing.InOutQuad }
                        }
                    }

                    Rectangle {
                        x: 4
                        anchors.bottom: parent.bottom
                        width: 2
                        height: 11
                        radius: 1
                        color: workspaces.colorAcento()

                        SequentialAnimation on height {
                            running: workspaces.reproduciendo
                            loops: Animation.Infinite
                            NumberAnimation { to: 5; duration: 220; easing.type: Easing.InOutQuad }
                            NumberAnimation { to: 14; duration: 320; easing.type: Easing.InOutQuad }
                            NumberAnimation { to: 7; duration: 260; easing.type: Easing.InOutQuad }
                        }
                    }

                    Rectangle {
                        x: 8
                        anchors.bottom: parent.bottom
                        width: 2
                        height: 9
                        radius: 1
                        color: workspaces.colorAcento()

                        SequentialAnimation on height {
                            running: workspaces.reproduciendo
                            loops: Animation.Infinite
                            NumberAnimation { to: 14; duration: 300; easing.type: Easing.InOutQuad }
                            NumberAnimation { to: 6; duration: 200; easing.type: Easing.InOutQuad }
                            NumberAnimation { to: 12; duration: 280; easing.type: Easing.InOutQuad }
                        }
                    }

                    Rectangle {
                        x: 12
                        anchors.bottom: parent.bottom
                        width: 2
                        height: 12
                        radius: 1
                        color: workspaces.colorAcento()

                        SequentialAnimation on height {
                            running: workspaces.reproduciendo
                            loops: Animation.Infinite
                            NumberAnimation { to: 6; duration: 260; easing.type: Easing.InOutQuad }
                            NumberAnimation { to: 10; duration: 240; easing.type: Easing.InOutQuad }
                            NumberAnimation { to: 4; duration: 300; easing.type: Easing.InOutQuad }
                        }
                    }

                    Rectangle {
                        x: 16
                        anchors.bottom: parent.bottom
                        width: 2
                        height: 5
                        radius: 1
                        color: workspaces.colorAcento()

                        SequentialAnimation on height {
                            running: workspaces.reproduciendo
                            loops: Animation.Infinite
                            NumberAnimation { to: 9; duration: 320; easing.type: Easing.InOutQuad }
                            NumberAnimation { to: 3; duration: 220; easing.type: Easing.InOutQuad }
                            NumberAnimation { to: 13; duration: 280; easing.type: Easing.InOutQuad }
                        }
                    }
                }
            }

            // Artista pequeño y título grande en negrita, recortados con elipsis
            // para que la card no se estire hacia la derecha (L3, L6).
            Column {
                anchors.verticalCenter: parent.verticalCenter
                width: 150
                spacing: 0

                Text {
                    width: parent.width
                    text: workspaces.reproductor && workspaces.reproductor.trackArtist
                        ? String(workspaces.reproductor.trackArtist)
                        : (workspaces.reproductor && workspaces.reproductor.identity
                            ? String(workspaces.reproductor.identity) : "")
                    elide: Text.ElideRight
                    color: workspaces.colorPista()
                    opacity: 0.65
                    font.family: workspaces.paleta ? workspaces.paleta.familia : "monospace"
                    font.pixelSize: Math.max(9, (workspaces.paleta ? workspaces.paleta.tamanoTexto : 14) - 4)
                }

                Text {
                    width: parent.width
                    text: workspaces.reproductor && workspaces.reproductor.trackTitle
                        ? String(workspaces.reproductor.trackTitle)
                        : "Reproduciendo"
                    elide: Text.ElideRight
                    color: workspaces.colorPista()
                    font.family: workspaces.paleta ? workspaces.paleta.familia : "monospace"
                    font.pixelSize: workspaces.paleta ? workspaces.paleta.tamanoTexto : 14
                    font.weight: Font.Bold
                }
            }
        }

        // Nivel inferior: controles grandes, centrados bajo el título.
        Row {
            id: filaControles

            anchors.horizontalCenter: parent.horizontalCenter
            height: 44
            spacing: 16

            // Anterior: 36x36 con fondo tenue.
            Item {
                anchors.verticalCenter: parent.verticalCenter
                width: 36
                height: 36

                Rectangle {
                    anchors.fill: parent
                    radius: 18
                    color: workspaces.paleta
                        ? workspaces.paleta.alfa(workspaces.colorPista(), 0.10)
                        : "#1AF0EDE1"
                }

                Text {
                    anchors.centerIn: parent
                    text: "\u{F048}"
                    color: workspaces.colorPista()
                    opacity: workspaces.puedeAnterior() ? 0.95 : 0.3
                    font.family: workspaces.paleta ? workspaces.paleta.familia : "monospace"
                    font.pixelSize: 15
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: workspaces.puedeAnterior()
                    onClicked: workspaces.reproductor.previous()
                }
            }

            // Alternar: 44x44 relleno de acento con glifo de contraste.
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 44
                height: 44
                radius: 22
                color: workspaces.colorAcento()

                Text {
                    anchors.centerIn: parent
                    text: workspaces.reproduciendo ? "\u{F04C}" : "\u{F04B}"
                    color: workspaces.paleta ? workspaces.paleta.sobreAcento : "#111111"
                    font.family: workspaces.paleta ? workspaces.paleta.familia : "monospace"
                    font.pixelSize: 18
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: workspaces.puedeAlternar()
                    onClicked: workspaces.reproductor.togglePlaying()
                }
            }

            // Siguiente: 36x36 con fondo tenue.
            Item {
                anchors.verticalCenter: parent.verticalCenter
                width: 36
                height: 36

                Rectangle {
                    anchors.fill: parent
                    radius: 18
                    color: workspaces.paleta
                        ? workspaces.paleta.alfa(workspaces.colorPista(), 0.10)
                        : "#1AF0EDE1"
                }

                Text {
                    anchors.centerIn: parent
                    text: "\u{F051}"
                    color: workspaces.colorPista()
                    opacity: workspaces.puedeSiguiente() ? 0.95 : 0.3
                    font.family: workspaces.paleta ? workspaces.paleta.familia : "monospace"
                    font.pixelSize: 15
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: workspaces.puedeSiguiente()
                    onClicked: workspaces.reproductor.next()
                }
            }
        }
    }
}
