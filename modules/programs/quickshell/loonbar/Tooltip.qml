import QtQuick
import Quickshell

// Globo de ayuda: una ventana emergente anclada al ítem que la invoca.
//
// Se usa también para el calendario del reloj, así que el texto puede ser
// multilínea y se dibuja en la misma tipografía monoespaciada de la barra, que
// mantiene alineadas las columnas del calendario.
PopupWindow {
    id: globo

    property Item objetivo: null
    property string texto: ""
    property bool mostrar: false
    property var paleta: null

    visible: globo.mostrar && globo.texto !== ""
    color: "transparent"

    anchor.item: globo.objetivo
    anchor.edges: Edges.Bottom
    anchor.gravity: Edges.Bottom
    anchor.margins.top: 6

    implicitWidth: etiqueta.implicitWidth + 24
    implicitHeight: etiqueta.implicitHeight + 16

    Rectangle {
        anchors.fill: parent
        radius: 10
        color: globo.paleta ? globo.paleta.alfa(globo.paleta.surface, 0.96) : "#F51B2629"
        border.width: 1
        border.color: globo.paleta ? globo.paleta.alfa(globo.paleta.foreground, 0.35) : "#59F0EDE1"

        Text {
            id: etiqueta
            anchors.centerIn: parent
            text: globo.texto
            color: globo.paleta ? globo.paleta.foreground : "#F0EDE1"
            font.family: globo.paleta ? globo.paleta.familia : "monospace"
            font.pixelSize: 14
            font.weight: Font.Medium
            lineHeight: 1.15
        }
    }
}
