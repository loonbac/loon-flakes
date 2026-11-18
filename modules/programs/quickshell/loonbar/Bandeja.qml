import QtQuick
import Quickshell.Services.SystemTray

// Bandeja del sistema (StatusNotifier).
//
// Los iconos llegan como imagen ya resuelta por Quickshell; si una aplicación no
// publica icono se dibuja un punto para que el ítem siga siendo visible y
// clicable.
Row {
    id: bandeja

    property var paleta: null
    // Ventana de la barra: los menús de la bandeja se anclan a ella. Es una
    // ventana (QObject), no un Item, así que el tipo es `var`.
    property var ventana: null

    spacing: 6
    height: 44
    visible: repetidor.count > 0

    Repeater {
        id: repetidor
        model: SystemTray.items.values

        delegate: Item {
            id: entrada
            required property var modelData

            width: 20
            height: 44

            Image {
                id: glifo
                anchors.centerIn: parent
                width: 18
                height: 18
                source: entrada.modelData.icon
                sourceSize.width: 18
                sourceSize.height: 18
                fillMode: Image.PreserveAspectFit
                smooth: true
            }

            Text {
                anchors.centerIn: parent
                visible: glifo.status === Image.Error || entrada.modelData.icon === ""
                text: "•"
                color: bandeja.paleta ? bandeja.paleta.foreground : "#F0EDE1"
                font.pixelSize: 12
            }

            MouseArea {
                id: ratonTray
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                hoverEnabled: true

                onClicked: evento => {
                    const item = entrada.modelData;
                    if (evento.button === Qt.RightButton) {
                        if (item.hasMenu) {
                            const punto = entrada.mapToItem(null, 0, entrada.height);
                            item.display(bandeja.ventana, Math.round(punto.x), Math.round(punto.y));
                        }
                        return;
                    }
                    item.activate();
                }

                onWheel: evento => entrada.modelData.scroll(evento.angleDelta.y, false)
            }

            Tooltip {
                objetivo: entrada
                texto: {
                    const item = entrada.modelData;
                    const titulo = item.tooltipTitle || item.title || "";
                    const detalle = item.tooltipDescription || "";
                    if (titulo !== "" && detalle !== "")
                        return titulo + "\n" + detalle;
                    return titulo !== "" ? titulo : detalle;
                }
                mostrar: ratonTray.containsMouse
                paleta: bandeja.paleta
            }
        }
    }
}
