import QtQuick
import org.kde.kwin as KWin

Rectangle {
    id: ghost
    property var destination: null
    property string sourceId: ""
    property var lastDestination: ({ x: 0, y: 0, width: 0, height: 0 })
    property string lastSourceId: ""
    property bool positioned: false
    readonly property bool animatePosition: positioned && destination !== null
    onDestinationChanged: {
        if (destination) {
            lastDestination = destination;
            Qt.callLater(function() { if (ghost.destination) ghost.positioned = true; });
        }
    }
    onSourceIdChanged: { if (sourceId) lastSourceId = sourceId; }
    onOpacityChanged: { if (opacity === 0) positioned = false; }
    x: lastDestination.x
    y: lastDestination.y
    width: lastDestination.width
    height: lastDestination.height
    opacity: destination !== null && sourceId !== "" ? 1 : 0
    visible: opacity > 0
    z: 10
    radius: 7
    color: "#4078a7ff"
    border.color: "#a8c7ff"
    border.width: 3
    Behavior on opacity { NumberAnimation { duration: 90 } }
    Behavior on x { enabled: ghost.animatePosition; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
    Behavior on y { enabled: ghost.animatePosition; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
    Behavior on width { enabled: ghost.animatePosition; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
    Behavior on height { enabled: ghost.animatePosition; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
    KWin.WindowThumbnail {
        anchors.fill: parent
        anchors.margins: 5
        wId: ghost.lastSourceId
        opacity: 0.35
    }
}
