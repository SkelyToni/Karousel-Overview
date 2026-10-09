import QtQuick
import Qt5Compat.GraphicalEffects
import org.kde.kwin as KWin
import "Style.js" as Style

// One desktop in the overview: its wallpaper and a horizontally scrolling
// strip of window previews in Karousel's column order.
Item {
    id: desktopRow
    required property int index
    required property var screenView     // the overview's per-screen view
    required property var overview       // the effect
    required property Item token         // drag token shared by the view
    readonly property var modelData: screenView.rows[index]
    property bool scrollInitialized: false
    property real closingOffsetX: 0
    readonly property real scrollPosition: strip.contentX
    property var renderedWindows: []
    property var verticalOffsets: ({})

    // Coordinates: the snapshot's desktop x is screen-relative with Karousel's
    // scroll added, at full scale. These helpers are the only place that maps
    // it into this row; keep every position on them.
    readonly property real inset: Math.max(0, (strip.width - screenView.screen.geometry.width * screenView.zoom) / 2)
    readonly property real originPadding: Math.max(0, -modelData.viewX * screenView.zoom)
    // Width of all columns at overview scale, with full column spacing.
    readonly property real columnsExtent: modelData.width * screenView.zoom
        + Math.max(0, modelData.columns.length - 1) * screenView.columnSpacing
    // Strip content x of desktop x, plus the gap opened before tiled column
    // `columnIndex` (floating windows pass -1).
    function stripX(x, columnIndex) {
        return inset + originPadding + x * screenView.zoom + Math.max(0, columnIndex || 0) * screenView.columnGapExtra;
    }
    // Strip scroll that shows exactly Karousel's current view.
    readonly property real homeContentX: originPadding + modelData.viewX * screenView.zoom
    // Position on this row's wallpaper, which is the screen once closed.
    function wallpaperX(x) { return (x - modelData.viewX) * screenView.zoom; }
    // Where Karousel's view starts on screen, in `item` coordinates.
    function viewportOrigin(item) { return strip.contentItem.mapToItem(item, stripX(modelData.viewX), 0); }

    readonly property int previewCount: previewRepeater.count
    function previewItem(index) { return previewRepeater.itemAt(index); }
    function scroll(delta) { horizontalMotion.scroll(delta); }
    function pan(delta) { horizontalMotion.pan(delta); }
    // Column boundary nearest to strip content x.
    function insertionPosition(x) {
        for (var i = 0; i < modelData.columns.length; ++i) {
            var column = modelData.columns[i];
            if (x < stripX(column.x + column.width / 2, i)) return i;
        }
        return modelData.columns.length;
    }
    // Closing, see the view's beginClosing(). Stops scrolling and returns
    // the strip's on-screen position, independent of origin padding.
    function captureScroll() {
        horizontalMotion.stop();
        strip.cancelFlick();
        return strip.contentX - originPadding;
    }
    // Restores a captured position after a refresh and aims the closing pan
    // at Karousel's current view.
    function prepareClose(captured) {
        horizontalMotion.stop();
        strip.cancelFlick();
        if (captured !== null && captured !== undefined) strip.contentX = captured + originPadding;
        closingOffsetX = strip.contentX - homeContentX;
    }
    function ensureWindow(window) {
        var center = stripX(window.x + window.width / 2, window.columnIndex);
        horizontalMotion.animateTo(center - strip.width / 2);
    }
    // Keep existing previews in their order so live thumbnails survive a
    // refresh, and work out how far to lift each column to center it.
    function updateWindows() {
        var next = modelData.windows;
        var bounds = {};
        next.forEach(function(window) {
            if (!window.tiled) return;
            var extent = bounds[window.columnIndex];
            if (!extent) bounds[window.columnIndex] = { top: window.y, bottom: window.y + window.height };
            else {
                extent.top = Math.min(extent.top, window.y);
                extent.bottom = Math.max(extent.bottom, window.y + window.height);
            }
        });
        var offsets = {};
        Object.keys(bounds).forEach(function(key) {
            offsets[key] = (screenView.screen.geometry.height - bounds[key].top - bounds[key].bottom) / 2;
        });
        verticalOffsets = offsets;
        var lookup = {};
        next.forEach(function(window) { lookup[window.id] = window; });
        var order = renderedWindows.map(function(window) { return window.id; })
            .filter(function(id) { return lookup[id] !== undefined; });
        next.forEach(function(window) { if (order.indexOf(window.id) < 0) order.push(window.id); });
        renderedWindows = order.map(function(id) { return lookup[id]; });
    }
    onModelDataChanged: updateWindows()

    ScrollMotion {
        id: horizontalMotion
        viewport: strip; axis: "contentX"
        maximum: strip.contentWidth - strip.width
    }
    // The desktop viewport stays centered while its windows scroll.
    Item {
        id: desktopWallpaper
        anchors.horizontalCenter: parent.horizontalCenter
        width: desktopRow.screenView.screen.geometry.width * desktopRow.screenView.zoom
        height: parent.height
        KWin.DesktopBackground {
            anchors.fill: parent
            activity: KWin.Workspace.currentActivity
            desktop: desktopRow.modelData.desktop
            outputName: desktopRow.screenView.screen.name
            opacity: 1 - Style.desktopDim * desktopRow.overview.reveal
        }
        // KWin blurs the wallpaper behind translucent windows. While the
        // transition shows real-size windows, back them with the same kind of
        // blur so the handoff to the desktop does not change them.
        Loader {
            id: blurBacking
            anchors.fill: parent
            active: desktopRow.modelData.current && desktopRow.overview.chrome < 1
            sourceComponent: Item {
                property alias blur: blurred
                KWin.DesktopBackground {
                    id: blurSource
                    anchors.fill: parent
                    activity: KWin.Workspace.currentActivity
                    desktop: desktopRow.modelData.desktop
                    outputName: desktopRow.screenView.screen.name
                    visible: false
                }
                FastBlur { id: blurred; anchors.fill: parent; source: blurSource; radius: Style.translucentBlur; visible: false }
            }
        }
        Rectangle {
            anchors.fill: parent
            color: "transparent"
            radius: Style.desktopRadius * desktopRow.overview.chrome
            border.width: desktopRow.overview.chrome
            opacity: desktopRow.overview.chrome
            border.color: desktopRow.index === desktopRow.screenView.selectedRow ? Style.desktopBorderSelected : Style.desktopBorder
        }
        MouseArea {
            anchors.fill: parent
            onClicked: desktopRow.screenView.activate("", desktopRow.modelData.id)
        }
    }
    Flickable {
        id: strip
        anchors.fill: parent
        anchors.leftMargin: Style.stripMargin
        anchors.rightMargin: Style.stripMargin
        // Keep clipping stable throughout the zoom; the output clips the scene.
        clip: false
        interactive: !desktopRow.overview.closing && !desktopRow.overview.gesturing
        contentItem.transform: Translate {
            x: desktopRow.overview.closing ? desktopRow.closingOffsetX * desktopRow.screenView.cameraTravel : 0
        }
        contentWidth: Math.max(width, desktopRow.stripX(0) + desktopRow.columnsExtent + desktopRow.inset)
        contentHeight: height
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.HorizontalFlick
        Component.onCompleted: {
            var saved = desktopRow.screenView.scrollPositions[desktopRow.modelData.id];
            contentX = Math.max(0, Math.min(contentWidth - width,
                saved === undefined ? desktopRow.homeContentX : saved));
            desktopRow.scrollInitialized = true;
        }
        onMovementStarted: horizontalMotion.stop()
        onContentXChanged: {
            var view = desktopRow.screenView;
            if (desktopRow.scrollInitialized)
                view.scrollPositions[desktopRow.modelData.id] = contentX;
            if (desktopRow.overview.draggedId && view.dropOwner && view.dropPreview &&
                view.dropPreview.desktopId === desktopRow.modelData.id)
                view.dropOwner.updatePreview();
        }
        // Retain the full row's click/drop area, but let off-screen windows
        // sit directly over the blurred overview backdrop.
        Item {
            id: columnArea
            x: desktopRow.stripX(0)
            width: desktopRow.columnsExtent
            height: strip.height
            MouseArea {
                anchors.fill: parent
                onClicked: desktopRow.screenView.activate("", desktopRow.modelData.id)
            }
            // Dropping between previews inserts a new column there.
            DropArea {
                id: columnDrop
                anchors.fill: parent
                keys: ["scrolloverview-window"]
                function updatePreview() {
                    var point = desktopRow.token.mapToItem(columnDrop, 0, 0);
                    desktopRow.screenView.previewDrop(desktopRow.modelData,
                        desktopRow.insertionPosition(columnArea.x + point.x), "", columnDrop);
                }
                onEntered: updatePreview()
                onPositionChanged: updatePreview()
                onExited: desktopRow.screenView.clearDrop(columnDrop)
                onDropped: function(drop) {
                    var position = desktopRow.insertionPosition(columnArea.x + drop.x);
                    desktopRow.screenView.moveWindow(desktopRow.overview.draggedId, desktopRow.modelData.id, position, "");
                    desktopRow.screenView.clearDrop(columnDrop);
                    drop.acceptProposedAction();
                }
            }
        }
        Repeater {
            id: previewRepeater
            model: desktopRow.renderedWindows.length
            delegate: WindowPreview {
                row: desktopRow
                screenView: desktopRow.screenView
                overview: desktopRow.overview
                token: desktopRow.token
                translucentBacking: blurBacking.item ? blurBacking.item.blur : null
            }
        }
        DropGhost {
            readonly property var plan: desktopRow.screenView.dropPreview
                && desktopRow.screenView.dropPreview.desktopId === desktopRow.modelData.id ? desktopRow.screenView.dropPreview : null
            sourceId: desktopRow.overview.draggedId
            destination: plan ? {
                x: desktopRow.stripX(plan.x, plan.columnIndex),
                y: plan.y * desktopRow.screenView.zoom,
                width: plan.width * desktopRow.screenView.zoom,
                height: plan.height * desktopRow.screenView.zoom
            } : null
        }
        // Right-drag pans the row.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.RightButton
            preventStealing: true
            property real previousX: 0
            onPressed: function(mouse) { previousX = mouse.x; horizontalMotion.stop(); }
            onPositionChanged: function(mouse) {
                if (pressed) { desktopRow.pan(previousX - mouse.x); previousX = mouse.x; }
            }
        }
    }
}
