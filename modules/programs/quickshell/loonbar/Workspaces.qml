import QtQuick

// Workspaces de niri.
//
// Se filtran por la salida del monitor que dibuja esta barra: `niri msg --json
// workspaces` devuelve todos los workspaces de todos los monitores y cada barra
// muestra solo los suyos.
Row {
    id: workspaces

    property var estado: null
    property var paleta: null
    property string salida: ""

    spacing: 3
    height: 44

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
        id: repetidor
        model: workspaces.lista()

        delegate: Rectangle {
            id: celda
            required property var modelData

            width: Math.max(56, etiqueta.implicitWidth + 24)
            height: 44
            radius: 10
            color: workspaces.colorFondo(celda.modelData)

            // Redondear solo los extremos de la tira; las esquinas interiores
            // se cuadran para que no queden muescas entre celdas.
            Rectangle {
                visible: index > 0
                anchors.left: parent.left
                anchors.top: parent.top
                width: celda.radius
                height: parent.height
                color: celda.color
            }

            Rectangle {
                visible: index < repetidor.count - 1
                anchors.right: parent.right
                anchors.top: parent.top
                width: celda.radius
                height: parent.height
                color: celda.color
            }

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
