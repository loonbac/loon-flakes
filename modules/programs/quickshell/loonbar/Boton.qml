import QtQuick

// Ítem clicable de la barra: glifo y/o texto visibles, tooltip automático y
// eventos de ratón reenviados como señales.
//
// Los módulos de la barra se escriben declarando uno de estos y conectando sus
// señales, así ningún ítem reimplementa el área de ratón ni el globo de ayuda.
Item {
    id: boton

    property var paleta: null
    property string icono: ""
    property string texto: ""
    property string tooltip: ""
    property color colorTexto: paleta ? paleta.foreground : "#F0EDE1"
    property color colorIcono: boton.colorTexto
    property int tamanoIcono: paleta ? paleta.tamanoIcono : 15
    property int tamanoTexto: paleta ? paleta.tamanoTexto : 13
    // Un módulo sin datos (brillo no disponible, sin batería) se oculta, pero
    // debe seguir existiendo para no romper el enlazado de sus señales.
    property bool habilitado: true

    signal clic
    signal clicDerecho
    signal ruedaArriba
    signal ruedaAbajo

    visible: boton.habilitado
    width: fila.width + 12
    height: 44

    Row {
        id: fila
        anchors.centerIn: parent
        spacing: 4

        Text {
            visible: boton.icono !== ""
            text: boton.icono
            color: boton.colorIcono
            font.family: boton.paleta ? boton.paleta.familia : "monospace"
            font.pixelSize: boton.tamanoIcono
            font.weight: Font.DemiBold
            height: 44
            verticalAlignment: Text.AlignVCenter
        }

        Text {
            visible: boton.texto !== ""
            text: boton.texto
            color: boton.colorTexto
            font.family: boton.paleta ? boton.paleta.familia : "monospace"
            font.pixelSize: boton.tamanoTexto
            font.weight: Font.DemiBold
            height: 44
            verticalAlignment: Text.AlignVCenter
        }
    }

    MouseArea {
        id: raton
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        hoverEnabled: true

        onClicked: evento => {
            if (evento.button === Qt.RightButton)
                boton.clicDerecho();
            else
                boton.clic();
        }

        onWheel: evento => {
            if (evento.angleDelta.y > 0)
                boton.ruedaArriba();
            else if (evento.angleDelta.y < 0)
                boton.ruedaAbajo();
        }
    }

    Tooltip {
        objetivo: boton
        texto: boton.tooltip
        mostrar: raton.containsMouse
        paleta: boton.paleta
    }
}
