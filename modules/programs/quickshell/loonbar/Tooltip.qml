import QtQuick
import Quickshell

// Globo de ayuda: una ventana emergente anclada al ítem que la invoca.
//
// Por defecto dibuja texto multilínea con la tipografía de la barra. Si el
// invocador pasa un `contenido`, se dibuja ese componente en su lugar: así el
// calendario del reloj puede colorear el día actual sin convertir el globo en
// un cálculo de columnas con caracteres monoespaciados.
PopupWindow {
    id: globo

    property Item objetivo: null
    property string texto: ""
    property Component contenido: null
    property bool mostrar: false
    property var paleta: null

    visible: globo.mostrar && (globo.texto !== "" || globo.contenido !== null)
    color: "transparent"

    anchor.item: globo.objetivo
    anchor.edges: Edges.Bottom
    anchor.gravity: Edges.Bottom
    anchor.margins.top: 6

    readonly property int anchoTexto: Math.min(etiqueta.implicitWidth, 620)

    implicitWidth: (globo.contenido ? cargaContenido.implicitWidth : globo.anchoTexto) + 24
    implicitHeight: (globo.contenido ? cargaContenido.implicitHeight : etiqueta.implicitHeight) + 16

    Rectangle {
        anchors.fill: parent
        radius: 10
        color: globo.paleta ? globo.paleta.alfa(globo.paleta.surface, 0.96) : "#F51B2629"
        border.width: 1
        border.color: globo.paleta ? globo.paleta.alfa(globo.paleta.foreground, 0.35) : "#59F0EDE1"

        Text {
            id: etiqueta
            visible: globo.contenido === null
            anchors.centerIn: parent
            text: globo.texto
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            width: globo.anchoTexto
            color: globo.paleta ? globo.paleta.foreground : "#F0EDE1"
            font.family: globo.paleta ? globo.paleta.familia : "monospace"
            font.pixelSize: 14
            font.weight: Font.Medium
            lineHeight: 1.15
        }

        Loader {
            id: cargaContenido
            visible: globo.contenido !== null
            sourceComponent: globo.contenido
            anchors.centerIn: parent
        }
    }
}
