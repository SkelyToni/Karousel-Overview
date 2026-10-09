import QtQuick
import org.kde.kwin as KWin
import "Style.js" as Style

// One window in a desktop row: live thumbnail, selection, caption, and the
// drag source and stacking drop target for that window.
Item {
    id: preview
    required property int index
    required property Item row           // the DesktopRow holding this preview
    required property var screenView     // the overview's per-screen view
    required property var overview       // the effect
    required property Item token         // drag token shared by the view
    // Blurred wallpaper standing in for KWin's blur behind translucent windows.
    property Item translucentBacking: null
    readonly property var modelData: row.renderedWindows[index]
    readonly property bool selected: modelData.id === screenView.selectedWindow
    readonly property bool animateGeometry: overview.reveal === 1 && !overview.animating && !overview.closing
        && !screenView.geometryLocked && !overview.draggedId

    x: row.stripX(modelData.x, modelData.columnIndex)
    // Center each complete column in the wallpaper during overview, then
    // restore desktop coordinates for closing.
    y: (modelData.y + (modelData.tiled ? row.verticalOffsets[modelData.columnIndex] || 0 : 0)
        * overview.reveal) * screenView.zoom
    width: modelData.width * screenView.zoom
    height: modelData.height * screenView.zoom
    z: modelData.tiled ? 1 : 2
    Behavior on x { enabled: preview.animateGeometry; NumberAnimation { duration: Style.previewSlideMs; easing.type: Easing.OutCubic } }
    Behavior on y { enabled: preview.animateGeometry; NumberAnimation { duration: Style.previewSlideMs; easing.type: Easing.OutCubic } }
    Behavior on width { enabled: preview.animateGeometry; NumberAnimation { duration: Style.previewSlideMs; easing.type: Easing.OutCubic } }
    Behavior on height { enabled: preview.animateGeometry; NumberAnimation { duration: Style.previewSlideMs; easing.type: Easing.OutCubic } }

    Rectangle {
        anchors.fill: parent
        anchors.margins: preview.selected ? -Style.selectionWidth * preview.overview.chrome : 0
        radius: Style.previewRadius * preview.overview.chrome
        // Fades like the rest of the chrome, so translucent windows end the
        // transition over the blur KWin draws behind them.
        color: Qt.alpha(Style.previewBacking, preview.overview.chrome)
        border.width: preview.selected ? Style.selectionWidth * preview.overview.chrome : 0
        border.color: Style.accent
    }
    ShaderEffectSource {
        anchors.fill: parent
        visible: sourceItem !== null
        sourceItem: preview.translucentBacking
        // The wallpaper under the window once it is back on the desktop.
        sourceRect: Qt.rect(preview.row.wallpaperX(preview.modelData.x),
            preview.modelData.y * preview.screenView.zoom, preview.width, preview.height)
    }
    KWin.WindowThumbnail {
        anchors.fill: parent
        wId: preview.modelData.id
        opacity: preview.overview.draggedId === preview.modelData.id ? 0.5 : 1
        Behavior on opacity { NumberAnimation { duration: Style.dragFadeMs } }
    }
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Style.captionHeight
        color: Style.captionBackground
        opacity: preview.overview.chrome * (previewMouse.containsMouse || preview.selected ? 1 : 0)
        Behavior on opacity { NumberAnimation { duration: Style.captionFadeMs } }
        Text {
            anchors.fill: parent
            anchors.margins: 5
            text: preview.modelData.caption
            elide: Text.ElideRight
            color: Style.captionText
            font.pixelSize: Style.captionFontSize
        }
    }
    // Dropping onto the middle of a preview stacks into its column.
    DropArea {
        id: stackDrop
        anchors.fill: parent
        anchors.margins: Math.min(preview.width, preview.height) * 0.2
        keys: ["scrolloverview-window"]
        function updatePreview() {
            preview.screenView.previewDrop(preview.row.modelData, preview.modelData.columnIndex, preview.modelData.id, stackDrop);
        }
        onEntered: updatePreview()
        onPositionChanged: updatePreview()
        onExited: preview.screenView.clearDrop(stackDrop)
        onDropped: function(drop) {
            if (preview.overview.draggedId !== preview.modelData.id) {
                preview.screenView.moveWindow(preview.overview.draggedId, preview.row.modelData.id,
                    preview.modelData.columnIndex, preview.modelData.id);
                drop.acceptProposedAction();
            }
            preview.screenView.clearDrop(stackDrop);
        }
    }
    MouseArea {
        id: previewMouse
        anchors.fill: parent
        hoverEnabled: true
        preventStealing: true
        drag.target: preview.token
        function select() {
            preview.screenView.selectedRow = preview.row.index;
            preview.screenView.selectedWindow = preview.modelData.id;
        }
        onEntered: {
            if (preview.overview.closing || preview.overview.gesturing || preview.overview.draggedId) return;
            select();
        }
        onPressed: function(mouse) {
            select();
            var point = mapToItem(preview.screenView, mouse.x, mouse.y);
            preview.token.x = point.x;
            preview.token.y = point.y;
        }
        onClicked: preview.screenView.activate(preview.modelData.id, preview.row.modelData.id)
        onReleased: {
            if (preview.overview.draggedId) preview.token.Drag.drop();
            preview.overview.draggedId = "";
            preview.overview.revision++;
        }
        onCanceled: preview.overview.draggedId = ""
        onPositionChanged: {
            if (drag.active) preview.overview.draggedId = preview.modelData.id;
        }
    }
}
