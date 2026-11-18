import QtQuick
import Quickshell

// Vista expandida de la isla: sale de la card de workspaces al mantener el
// puntero sobre ella, como el estado Expanded del Dynamic Island. Conserva la
// jerarquía concéntrica, el radio grande y los controles esenciales.
PopupWindow {
    id: isla

    property Item objetivo: null
    property var reproductor: null
    property var paleta: null
    property bool mostrar: false

    signal entroRaton
    signal salioRaton

    visible: isla.mostrar && isla.reproductor !== null
    color: "transparent"

    anchor.item: isla.objetivo
    anchor.edges: Edges.Bottom
    anchor.gravity: Edges.Bottom
    anchor.margins.top: 10

    implicitWidth: 372
    implicitHeight: 132

    Rectangle {
        anchors.fill: parent
        radius: 18
        color: isla.paleta ? isla.paleta.alfa(isla.paleta.surface, 0.98) : "#F51B2629"
        border.width: 1
        border.color: isla.paleta ? isla.paleta.alfa(isla.paleta.foreground, 0.30) : "#4DF0EDE1"

        Column {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 8

            Text {
                width: parent.width
                text: isla.reproductor ? String(isla.reproductor.trackArtist || isla.reproductor.identity || "") : ""
                color: isla.paleta ? isla.paleta.foreground : "#F0EDE1"
                opacity: 0.75
                font.family: isla.paleta ? isla.paleta.familia : "monospace"
                font.pixelSize: 11
                elide: Text.ElideRight
                maximumLineCount: 1
            }

            Text {
                width: parent.width
                text: isla.reproductor ? String(isla.reproductor.trackTitle || "") : ""
                color: isla.paleta ? isla.paleta.foreground : "#F0EDE1"
                font.family: isla.paleta ? isla.paleta.familia : "monospace"
                font.pixelSize: 16
                font.weight: Font.Bold
                elide: Text.ElideRight
                maximumLineCount: 1
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 12

                Item {
                    width: 36
                    height: 36

                    Rectangle {
                        anchors.fill: parent
                        radius: 18
                        color: isla.paleta ? isla.paleta.alfa(isla.paleta.foreground, 0.10) : "#1AFFFFFF"
                    }

                    Text {
                        anchors.centerIn: parent
                        text: "\u{F048}"
                        color: isla.paleta ? isla.paleta.foreground : "#F0EDE1"
                        opacity: isla.reproductor && isla.reproductor.canGoPrevious ? 1 : 0.35
                        font.family: isla.paleta ? isla.paleta.familia : "monospace"
                        font.pixelSize: 15
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: isla.reproductor && isla.reproductor.canGoPrevious
                        onClicked: isla.reproductor.previous()
                    }
                }

                Item {
                    width: 44
                    height: 44

                    Rectangle {
                        anchors.fill: parent
                        radius: 22
                        color: isla.paleta ? isla.paleta.accent : "#AB9A5E"
                    }

                    Text {
                        anchors.centerIn: parent
                        text: isla.reproductor && isla.reproductor.isPlaying ? "\u{F04C}" : "\u{F04B}"
                        color: isla.paleta ? isla.paleta.sobreAcento : "#111111"
                        font.family: isla.paleta ? isla.paleta.familia : "monospace"
                        font.pixelSize: 17
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: isla.reproductor && isla.reproductor.canTogglePlaying
                        onClicked: isla.reproductor.togglePlaying()
                    }
                }

                Item {
                    width: 36
                    height: 36

                    Rectangle {
                        anchors.fill: parent
                        radius: 18
                        color: isla.paleta ? isla.paleta.alfa(isla.paleta.foreground, 0.10) : "#1AFFFFFF"
                    }

                    Text {
                        anchors.centerIn: parent
                        text: "\u{F051}"
                        color: isla.paleta ? isla.paleta.foreground : "#F0EDE1"
                        opacity: isla.reproductor && isla.reproductor.canGoNext ? 1 : 0.35
                        font.family: isla.paleta ? isla.paleta.familia : "monospace"
                        font.pixelSize: 15
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: isla.reproductor && isla.reproductor.canGoNext
                        onClicked: isla.reproductor.next()
                    }
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            hoverEnabled: true
            onEntered: isla.entroRaton()
            onExited: isla.salioRaton()
        }
    }
}
