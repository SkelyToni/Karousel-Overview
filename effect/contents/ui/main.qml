import QtQuick
import Qt5Compat.GraphicalEffects
import org.kde.kwin as KWin
import "Bridge.js" as Bridge
import "Layout.js" as Layout
import "DropPreview.js" as DropPreview
import "Style.js" as Style

KWin.SceneEffect {
    id: effect
    property real reveal: 0
    property bool gesturing: false
    property bool gestureStartedOpen: false
    property bool closing: false
    property string draggedId: ""
    property int revision: 0
    // The backdrop keeps the wallpaper the overview opened from; following a
    // desktop switch would swap and re-blur it in the middle of closing.
    property var openedDesktop: null
    readonly property bool animating: gesturing || revealMotion.running
    // Window chrome (borders, captions, rounding) appears late while opening
    // and leaves early while closing, so the zoom itself stays uncluttered.
    readonly property real chrome: Math.max(0, Math.min(1, (reveal - Style.chromeStart) / (1 - Style.chromeStart)))

    ShortcutGuard { id: shortcutGuard; active: effect.visible }

    function begin() {
        if (!Bridge.ready()) {
            console.warn("Scroll Overview: restart the patched Karousel script first");
            return false;
        }
        if (!visible) {
            closing = false;
            openedDesktop = KWin.Workspace.currentDesktop;
            revealMotion.reset(0);
            Bridge.setVisible(true);
            visible = true;
        }
        return true;
    }
    function open() {
        if (begin()) {
            gesturing = false;
            revealMotion.animateTo(1);
        }
    }
    function prepareClose() {
        if (!closing) closing = true;
    }
    function finishClose() {
        visible = false;
        // Leave `closing` set: this runs inside the final animation tick, and
        // clearing it would drop the camera pan for that last rendered frame,
        // flashing the window the overview was opened from. begin() resets it.
        draggedId = "";
        Bridge.setVisible(false);
    }
    function close() {
        prepareClose();
        gesturing = false;
        if (reveal <= 0) { revealMotion.reset(0); finishClose(); }
        else revealMotion.animateTo(0);
    }
    function toggle() { if (visible) close(); else open(); }

    RevealMotion {
        id: revealMotion
        target: effect
        onFinished: {
            if (to === 0) effect.finishClose();
            else effect.closing = false;
        }
    }
    Timer {
        interval: Style.refreshIntervalMs
        repeat: true
        running: effect.visible && !effect.closing && !effect.draggedId && !effect.animating
        onTriggered: {
            if (!Bridge.ready()) effect.close();
            else effect.revision++;
        }
    }
    KWin.ShortcutHandler {
        name: "ScrollOverview"
        text: "Toggle Scroll Overview"
        sequence: "Meta+Ctrl+O"
        onActivated: effect.toggle()
    }
    KWin.SwipeGestureHandler {
        direction: KWin.SwipeGestureHandler.Direction.Up
        fingerCount: 4
        onProgressChanged: {
            if (!effect.gesturing) {
                effect.gestureStartedOpen = effect.visible;
                if (effect.gestureStartedOpen || !effect.begin()) return;
                effect.gesturing = true;
            }
            if (!effect.gestureStartedOpen) revealMotion.track(progress);
        }
        onActivated: {
            if (!effect.gestureStartedOpen) effect.open();
            effect.gesturing = false;
            effect.gestureStartedOpen = false;
        }
        onCancelled: {
            if (effect.gesturing && !effect.gestureStartedOpen) effect.close();
            effect.gesturing = false;
            effect.gestureStartedOpen = false;
        }
    }
    KWin.SwipeGestureHandler {
        direction: KWin.SwipeGestureHandler.Direction.Down
        fingerCount: 4
        onProgressChanged: {
            if (!effect.visible) return;
            effect.prepareClose();
            effect.gesturing = true;
            revealMotion.track(1 - progress);
        }
        onActivated: { if (effect.visible) effect.close(); }
        onCancelled: { if (effect.visible) effect.open(); }
    }
    Connections {
        target: KWin.Workspace
        function onCurrentActivityChanged() { if (effect.visible) effect.close(); }
    }
    Component.onDestruction: Bridge.setVisible(false)
    // The package directory names the installed revision.
    Component.onCompleted: console.log("Scroll Overview loaded from", Qt.resolvedUrl("."))

    delegate: FocusScope {
        id: view
        focus: true
        readonly property var screen: KWin.SceneView.screen
        property var rows: []
        readonly property real zoom: Style.zoom
        readonly property real rowHeight: screen.geometry.height * zoom
        readonly property real rowGap: Style.rowGap
        readonly property real rowStep: rowHeight + rowGap
        readonly property real columnSpacing: Style.columnSpacing
        readonly property real columnGapExtra: columnSpacing * effect.reveal
        // Interpolate scale geometrically so the zoom rate looks constant.
        readonly property real cameraScale: Math.pow(1 / zoom, 1 - effect.reveal)
        // Share of the closing pan applied at the current scale. Tying the pan to
        // the scale makes the camera a pure zoom about one fixed point, so the
        // destination window grows along a straight line instead of drifting.
        readonly property real cameraTravel: (1 - 1 / cameraScale) / (1 - zoom)
        property int selectedRow: 0
        property string selectedWindow: ""
        property bool initialized: false
        property string rowSignature: ""
        property var scrollPositions: ({})
        property real closingOffsetY: 0
        property var dropPreview: null
        property var dropOwner: null
        // Set before the closing refresh so every preview stops animating its
        // geometry first; relying on `closing` alone left that to signal order.
        property bool geometryLocked: false

        function previewDrop(row, position, stackId, owner) {
            if (!effect.draggedId || !Bridge.provider) { dropPreview = null; return; }
            var world = Bridge.provider.world;
            var layout = world.desktopManager.getDesktopInCurrentActivity(row.desktop);
            var client = Layout.findClient(Bridge.provider, effect.draggedId);
            var window = client ? world.clientManager.findTiledWindow(client) : null;
            if (!layout || !window) { dropPreview = null; return; }
            dropOwner = owner;
            dropPreview = DropPreview.plan(rows, effect.draggedId, row, position, stackId, {
                left: layout.tilingArea.x - screen.geometry.x,
                height: layout.tilingArea.height,
                screenHeight: screen.geometry.height,
                horizontalGap: layout.grid.config.gapsInnerHorizontal,
                verticalGap: layout.grid.config.gapsInnerVertical,
                preferredWidth: window.client.preferredWidth
            });
        }
        function clearDrop(owner) {
            if (dropOwner === owner) { dropOwner = null; dropPreview = null; }
        }

        function refresh() {
            if (effect.draggedId) return;
            var next = Layout.snapshot(Bridge.provider, screen);
            var nextSignature = Layout.signature(next);
            if (nextSignature === rowSignature) return;
            rowSignature = nextSignature;
            rows = next;
            selectedRow = Math.max(0, Math.min(selectedRow, rows.length - 1));
            if (!initialized) {
                initialized = true;
                for (var i = 0; i < rows.length; ++i) {
                    if (rows[i].current) selectedRow = i;
                    for (var j = 0; j < rows[i].windows.length; ++j)
                        if (rows[i].windows[j].focused) selectedWindow = rows[i].windows[j].id;
                }
                centerRow(selectedRow);
            }
        }
        // Vertical scroll that centers desktop row `index`.
        function rowContentY(index) { return index * rowStep; }
        function centerRow(index, animate) {
            var destination = rowContentY(index);
            if (animate) verticalMotion.animateTo(destination);
            else desktops.contentY = verticalMotion.clamp(destination);
        }
        function rowAt(x, y) {
            for (var i = 0; i < rowRepeater.count; ++i) {
                var row = rowRepeater.itemAt(i);
                var local = view.mapToItem(row, x, y);
                if (local.y >= 0 && local.y <= row.height) return row;
            }
            return rowRepeater.itemAt(selectedRow);
        }
        function scrollAxis(horizontal, delta, x, y) {
            if (effect.closing || effect.gesturing) return;
            if (horizontal) {
                var row = rowAt(x, y);
                if (row) row.scroll(delta);
            } else {
                verticalMotion.scroll(delta);
            }
        }
        function activate(id, desktopId) {
            if (effect.closing || effect.gesturing) return;
            if (!Layout.focus(Bridge.provider, id, desktopId)) return;
            // Closing refreshes the layout itself once previews stop animating
            // their geometry, so the focus change cannot start a competing slide.
            effect.close();
        }
        function navigateWindow(direction) {
            if (!rows.length) return;
            var windows = rows[selectedRow].windows;
            if (!windows.length) { selectedWindow = ""; return; }
            var index = windows.findIndex(function(w) { return w.id === selectedWindow; });
            index = index < 0 ? (direction < 0 ? windows.length - 1 : 0) :
                Math.max(0, Math.min(windows.length - 1, index + direction));
            selectedWindow = windows[index].id;
            var rowItem = rowRepeater.itemAt(selectedRow);
            if (rowItem) rowItem.ensureWindow(windows[index]);
        }
        function navigateDesktop(direction) {
            if (!rows.length) return;
            var oldWindows = rows[selectedRow].windows;
            var old = oldWindows.find(function(window) { return window.id === selectedWindow; });
            var center = old ? old.x + old.width / 2 : rows[selectedRow].viewX + screen.geometry.width / 2;
            selectedRow = Math.max(0, Math.min(rows.length - 1, selectedRow + direction));
            var windows = rows[selectedRow].windows;
            var nearest = null;
            windows.forEach(function(window) {
                if (!nearest || Math.abs(window.x + window.width / 2 - center) <
                    Math.abs(nearest.x + nearest.width / 2 - center)) nearest = window;
            });
            selectedWindow = nearest ? nearest.id : "";
            centerRow(selectedRow, true);
            var rowItem = rowRepeater.itemAt(selectedRow);
            if (rowItem && nearest) rowItem.ensureWindow(nearest);
        }
        Component.onCompleted: { refresh(); forceActiveFocus(); }
        Connections {
            target: effect
            function onDraggedIdChanged() {
                if (!effect.draggedId) { view.dropOwner = null; view.dropPreview = null; }
            }
            function onRevisionChanged() { view.refresh(); }
            function onClosingChanged() {
                view.geometryLocked = effect.closing;
                if (!effect.closing) return;
                verticalMotion.stop();
                desktops.cancelFlick();
                // Focusing a window rescrolls Karousel, which can change a row's
                // origin padding; keep each strip where it is on screen.
                var anchors = [];
                for (var j = 0; j < rowRepeater.count; ++j) {
                    var shown = rowRepeater.itemAt(j);
                    anchors.push(shown ? shown.holdScroll() : null);
                }
                view.refresh();
                for (var i = 0; i < view.rows.length; ++i) {
                    var row = rowRepeater.itemAt(i);
                    if (row) row.prepareClose(anchors[i]);
                    if (view.rows[i].current)
                        view.closingOffsetY = desktops.contentY - view.rowContentY(i);
                }
            }
        }
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
            event.accepted = true;
            if (event.key === Qt.Key_Escape) { effect.close(); return; }
            if (event.key === Qt.Key_O && (event.modifiers & Qt.MetaModifier) &&
                (event.modifiers & Qt.ControlModifier)) { effect.close(); return; }
            if (effect.closing || effect.gesturing || event.modifiers !== Qt.NoModifier) return;
            if (event.key === Qt.Key_Left) navigateWindow(-1);
            else if (event.key === Qt.Key_Right) navigateWindow(1);
            else if (event.key === Qt.Key_Up) navigateDesktop(-1);
            else if (event.key === Qt.Key_Down) navigateDesktop(1);
            else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && rows.length)
                activate(selectedWindow, rows[selectedRow].id);
        }

        // Input-only overlay: accepts wheel events over previews and empty space,
        // while leaving clicks, window dragging and Flickable panning available.
        Item {
            anchors.fill: parent
            z: 100
            WheelHandler {
                orientation: Qt.Horizontal
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                target: null
                onWheel: function(event) {
                    view.scrollAxis(true, event.pixelDelta.x ? -event.pixelDelta.x : event.angleDelta.x * Style.wheelAngleScale, event.x, event.y);
                    event.accepted = true;
                }
            }
            WheelHandler {
                orientation: Qt.Vertical
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                target: null
                onWheel: function(event) {
                    view.scrollAxis(false, event.pixelDelta.y ? -event.pixelDelta.y : event.angleDelta.y * Style.wheelAngleScale, event.x, event.y);
                    event.accepted = true;
                }
            }
        }

        ScrollMotion {
            id: verticalMotion
            viewport: desktops; axis: "contentY"
            maximum: desktops.contentHeight - desktops.height
            snapStep: view.rowStep
        }
        FrameAnimation {
            running: effect.draggedId !== ""
            onTriggered: {
                var elapsed = Math.min(40, frameTime * 1000);
                if (elapsed <= 0) return;
                // Scroll faster the closer the dragged window is to an edge.
                var edge = Style.edgeScroll;
                function push(position, extent, zone, speed) {
                    if (position < zone) return -speed * elapsed * Math.min(1, (zone - position) / zone);
                    if (position > extent - zone) return speed * elapsed * Math.min(1, (position - extent + zone) / zone);
                    return 0;
                }
                var row = view.rowAt(dragToken.x, dragToken.y);
                var dx = push(dragToken.x, view.width, edge.horizontalZone, edge.horizontalSpeed);
                var dy = push(dragToken.y, view.height, edge.verticalZone, edge.verticalSpeed);
                if (row && dx) row.pan(dx);
                if (dy) verticalMotion.pan(dy);
            }
        }

        // Same wallpaper source and blur radius as Plasma's built-in overview.
        // It stays opaque so edges uncovered by the zoom never flash dark;
        // only the dimming follows the transition.
        Item {
            anchors.fill: parent
            Rectangle { anchors.fill: parent; color: Style.backdropColor }
            KWin.DesktopBackground {
                id: wallpaper
                anchors.fill: parent
                activity: KWin.Workspace.currentActivity
                desktop: effect.openedDesktop || KWin.Workspace.currentDesktop
                outputName: view.screen.name
                visible: false
            }
            FastBlur { anchors.fill: parent; source: wallpaper; radius: Style.backdropBlur }
            Rectangle { anchors.fill: parent; color: Style.backdropColor; opacity: Style.backdropDim * effect.reveal }
        }
        Flickable {
            id: desktops
            anchors.fill: parent
            anchors.topMargin: Style.rowMargin
            anchors.bottomMargin: Style.rowMargin
            clip: false
            contentWidth: width
            contentHeight: rowColumn.height + height - view.rowHeight
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            onMovementStarted: verticalMotion.stop()
            onMovementEnded: if (!effect.closing) verticalMotion.finish()
            onContentYChanged: {
                if (view.initialized && !effect.closing && !verticalMotion.navigating)
                    view.selectedRow = Math.max(0, Math.min(view.rows.length - 1,
                        Math.round(contentY / view.rowStep)));
            }
            interactive: !effect.closing && !effect.gesturing
            contentItem.transform: Translate {
                y: effect.closing ? view.closingOffsetY * view.cameraTravel : 0
            }
            transform: Scale {
                origin.x: desktops.width / 2
                origin.y: desktops.height / 2
                xScale: view.cameraScale
                yScale: xScale
            }
            Column {
                id: rowColumn
                width: desktops.width
                y: (desktops.height - view.rowHeight) / 2
                spacing: view.rowGap
                Repeater {
                    id: rowRepeater
                    model: view.rows.length
                    delegate: Item {
                        id: desktopRow
                        required property int index
                        readonly property var modelData: view.rows[index]
                        width: rowColumn.width
                        height: view.rowHeight
                        property bool scrollInitialized: false
                        property real closingOffsetX: 0
                        readonly property real scrollPosition: strip.contentX
                        property var renderedWindows: []
                        property var verticalOffsets: ({})
                        function updateWindows() {
                            var lookup = {};
                            var next = modelData.windows;
                            var bounds = {};
                            next.forEach(function(window) {
                                if (!window.tiled) return;
                                var key = window.columnIndex;
                                var extent = bounds[key];
                                if (!extent) bounds[key] = { top: window.y, bottom: window.y + window.height };
                                else {
                                    extent.top = Math.min(extent.top, window.y);
                                    extent.bottom = Math.max(extent.bottom, window.y + window.height);
                                }
                            });
                            var offsets = {};
                            Object.keys(bounds).forEach(function(key) {
                                var extent = bounds[key];
                                offsets[key] = (view.screen.geometry.height - extent.top - extent.bottom) / 2;
                            });
                            verticalOffsets = offsets;
                            next.forEach(function(window) { lookup[window.id] = window; });
                            var order = renderedWindows.map(function(window) { return window.id; })
                                .filter(function(id) { return lookup[id] !== undefined; });
                            next.forEach(function(window) { if (order.indexOf(window.id) < 0) order.push(window.id); });
                            renderedWindows = order.map(function(id) { return lookup[id]; });
                        }
                        onModelDataChanged: updateWindows()
                        // Coordinates: the snapshot's desktop x is screen-relative with
                        // Karousel's scroll added, at full scale. These helpers are the only
                        // place that maps it into this row; keep every position on them.
                        readonly property real inset: Math.max(0, (strip.width - view.screen.geometry.width * view.zoom) / 2)
                        readonly property real originPadding: Math.max(0, -modelData.viewX * view.zoom)
                        // Width of all columns at overview scale, with full column spacing.
                        readonly property real columnsExtent: modelData.width * view.zoom
                            + Math.max(0, modelData.columns.length - 1) * view.columnSpacing
                        // Strip content x of desktop x, plus the gap opened before tiled
                        // column `columnIndex` (floating windows pass -1).
                        function stripX(x, columnIndex) {
                            return inset + originPadding + x * view.zoom + Math.max(0, columnIndex || 0) * view.columnGapExtra;
                        }
                        // Strip scroll that shows exactly Karousel's current view.
                        readonly property real homeContentX: originPadding + modelData.viewX * view.zoom
                        // Position on this row's wallpaper, which is the screen once closed.
                        function wallpaperX(x) { return (x - modelData.viewX) * view.zoom; }
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
                        function holdScroll() {
                            horizontalMotion.stop();
                            strip.cancelFlick();
                            return strip.contentX - originPadding;
                        }
                        function prepareClose(anchor) {
                            horizontalMotion.stop();
                            strip.cancelFlick();
                            if (anchor !== null && anchor !== undefined) strip.contentX = anchor + originPadding;
                            closingOffsetX = strip.contentX - homeContentX;
                        }
                        function ensureWindow(window) {
                            var center = stripX(window.x + window.width / 2, window.columnIndex);
                            horizontalMotion.animateTo(center - strip.width / 2);
                        }
                        ScrollMotion {
                            id: horizontalMotion
                            viewport: strip; axis: "contentX"
                            maximum: strip.contentWidth - strip.width
                        }
                        // The desktop viewport stays centered while its windows scroll.
                        Item {
                            id: desktopWallpaper
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: view.screen.geometry.width * view.zoom
                            height: parent.height
                            KWin.DesktopBackground {
                                anchors.fill: parent
                                activity: KWin.Workspace.currentActivity
                                desktop: desktopRow.modelData.desktop
                                outputName: view.screen.name
                                opacity: 1 - Style.desktopDim * effect.reveal
                            }
                            // KWin blurs the wallpaper behind translucent windows. While the
                            // transition shows real-size windows, back them with the same kind
                            // of blur so the handoff to the desktop does not change them.
                            Loader {
                                id: blurBacking
                                anchors.fill: parent
                                active: desktopRow.modelData.current && effect.chrome < 1
                                sourceComponent: Item {
                                    property alias blur: blurred
                                    KWin.DesktopBackground {
                                        id: blurSource
                                        anchors.fill: parent
                                        activity: KWin.Workspace.currentActivity
                                        desktop: desktopRow.modelData.desktop
                                        outputName: view.screen.name
                                        visible: false
                                    }
                                    FastBlur { id: blurred; anchors.fill: parent; source: blurSource; radius: Style.translucentBlur; visible: false }
                                }
                            }
                            Rectangle {
                                anchors.fill: parent
                                color: "transparent"
                                radius: Style.desktopRadius * effect.chrome
                                border.width: effect.chrome
                                opacity: effect.chrome
                                border.color: desktopRow.index === view.selectedRow ? Style.desktopBorderSelected : Style.desktopBorder
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: view.activate("", desktopRow.modelData.id)
                            }
                        }
                        Flickable {
                            id: strip
                            anchors.fill: parent
                            anchors.leftMargin: Style.stripMargin
                            anchors.rightMargin: Style.stripMargin
                            // Keep clipping stable throughout the zoom; the output clips the scene.
                            clip: false
                            interactive: !effect.closing && !effect.gesturing
                            contentItem.transform: Translate {
                                x: effect.closing ? desktopRow.closingOffsetX * view.cameraTravel : 0
                            }
                            contentWidth: Math.max(width, desktopRow.stripX(0) + desktopRow.columnsExtent + desktopRow.inset)
                            contentHeight: height
                            boundsBehavior: Flickable.StopAtBounds
                            flickableDirection: Flickable.HorizontalFlick
                            Component.onCompleted: {
                                var saved = view.scrollPositions[desktopRow.modelData.id];
                                contentX = Math.max(0, Math.min(contentWidth - width,
                                    saved === undefined ? desktopRow.homeContentX : saved));
                                desktopRow.scrollInitialized = true;
                            }
                            onMovementStarted: horizontalMotion.stop()
                            onContentXChanged: {
                                if (desktopRow.scrollInitialized)
                                    view.scrollPositions[desktopRow.modelData.id] = contentX;
                                if (effect.draggedId && view.dropOwner && view.dropPreview &&
                                    view.dropPreview.desktopId === desktopRow.modelData.id)
                                    view.dropOwner.updatePreview();
                            }
                            // Retain the full row's click/drop area, but let off-screen
                            // windows sit directly over the blurred overview backdrop.
                            Item {
                                id: columnArea
                                x: desktopRow.stripX(0)
                                width: desktopRow.columnsExtent
                                height: strip.height
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: {
                                        view.activate("", desktopRow.modelData.id);
                                    }
                                }
                                DropArea {
                                    id: columnDrop
                                    anchors.fill: parent
                                    keys: ["scrolloverview-window"]
                                    function updatePreview() {
                                        var point = dragToken.mapToItem(columnDrop, 0, 0);
                                        view.previewDrop(desktopRow.modelData, desktopRow.insertionPosition(columnArea.x + point.x), "", columnDrop);
                                    }
                                    onEntered: updatePreview()
                                    onPositionChanged: updatePreview()
                                    onExited: view.clearDrop(columnDrop)
                                    onDropped: function(drop) {
                                        var position = desktopRow.insertionPosition(columnArea.x + drop.x);
                                        Layout.move(Bridge.provider, effect.draggedId, desktopRow.modelData.id, position, "");
                                        view.clearDrop(columnDrop);
                                        drop.acceptProposedAction();
                                    }
                                }
                            }
                            Repeater {
                                id: previewRepeater
                                model: desktopRow.renderedWindows.length
                                delegate: Item {
                                    id: preview
                                    required property int index
                                    readonly property var modelData: desktopRow.renderedWindows[index]
                                    readonly property bool animateGeometry: effect.reveal === 1 && !effect.animating && !effect.closing && !view.geometryLocked && !effect.draggedId
                                    x: desktopRow.stripX(modelData.x, modelData.columnIndex)
                                    // Center each complete column in the wallpaper during
                                    // overview, then restore desktop coordinates for closing.
                                    y: (modelData.y + (modelData.tiled ? desktopRow.verticalOffsets[modelData.columnIndex] || 0 : 0)
                                        * effect.reveal) * view.zoom
                                    width: modelData.width * view.zoom
                                    height: modelData.height * view.zoom
                                    z: modelData.tiled ? 1 : 2
                                    Behavior on x { enabled: preview.animateGeometry; NumberAnimation { duration: Style.previewSlideMs; easing.type: Easing.OutCubic } }
                                    Behavior on y { enabled: preview.animateGeometry; NumberAnimation { duration: Style.previewSlideMs; easing.type: Easing.OutCubic } }
                                    Behavior on width { enabled: preview.animateGeometry; NumberAnimation { duration: Style.previewSlideMs; easing.type: Easing.OutCubic } }
                                    Behavior on height { enabled: preview.animateGeometry; NumberAnimation { duration: Style.previewSlideMs; easing.type: Easing.OutCubic } }
                                    Rectangle {
                                        anchors.fill: parent
                                        anchors.margins: preview.modelData.id === view.selectedWindow ? -Style.selectionWidth * effect.chrome : 0
                                        radius: Style.previewRadius * effect.chrome
                                        // Fades like the rest of the chrome, so translucent windows end
                                        // the transition over the blur KWin draws behind them.
                                        color: Qt.alpha(Style.previewBacking, effect.chrome)
                                        border.width: preview.modelData.id === view.selectedWindow ? Style.selectionWidth * effect.chrome : 0
                                        border.color: Style.accent
                                    }
                                    ShaderEffectSource {
                                        anchors.fill: parent
                                        visible: sourceItem !== null
                                        sourceItem: blurBacking.item ? blurBacking.item.blur : null
                                        // The wallpaper under the window once it is back on the desktop.
                                        sourceRect: Qt.rect(desktopRow.wallpaperX(preview.modelData.x),
                                            preview.modelData.y * view.zoom, preview.width, preview.height)
                                    }
                                    KWin.WindowThumbnail {
                                        anchors.fill: parent
                                        wId: preview.modelData.id
                                        opacity: effect.draggedId === preview.modelData.id ? 0.5 : 1
                                        Behavior on opacity { NumberAnimation { duration: Style.dragFadeMs } }
                                    }
                                    Rectangle {
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.bottom: parent.bottom
                                        height: Style.captionHeight
                                        color: Style.captionBackground
                                        opacity: effect.chrome * (previewMouse.containsMouse || preview.modelData.id === view.selectedWindow ? 1 : 0)
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
                                    DropArea {
                                        id: stackDrop
                                        anchors.fill: parent
                                        anchors.margins: Math.min(preview.width, preview.height) * 0.2
                                        keys: ["scrolloverview-window"]
                                        function updatePreview() {
                                            view.previewDrop(desktopRow.modelData, preview.modelData.columnIndex, preview.modelData.id, stackDrop);
                                        }
                                        onEntered: updatePreview()
                                        onPositionChanged: updatePreview()
                                        onExited: view.clearDrop(stackDrop)
                                        onDropped: function(drop) {
                                            if (effect.draggedId !== preview.modelData.id) {
                                                Layout.move(Bridge.provider, effect.draggedId, desktopRow.modelData.id,
                                                    preview.modelData.columnIndex, preview.modelData.id);
                                                drop.acceptProposedAction();
                                            }
                                            view.clearDrop(stackDrop);
                                        }
                                    }
                                    MouseArea {
                                        id: previewMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onEntered: {
                                            if (effect.closing || effect.gesturing || effect.draggedId) return;
                                            view.selectedRow = desktopRow.index;
                                            view.selectedWindow = preview.modelData.id;
                                        }
                                        preventStealing: true
                                        drag.target: dragToken
                                        onPressed: function(mouse) {
                                            view.selectedRow = desktopRow.index;
                                            view.selectedWindow = preview.modelData.id;
                                            var point = mapToItem(view, mouse.x, mouse.y);
                                            dragToken.x = point.x;
                                            dragToken.y = point.y;
                                        }
                                        onClicked: {
                                            view.activate(preview.modelData.id, desktopRow.modelData.id);
                                        }
                                        onReleased: {
                                            if (effect.draggedId) dragToken.Drag.drop();
                                            effect.draggedId = "";
                                            effect.revision++;
                                        }
                                        onCanceled: { effect.draggedId = ""; }
                                        onPositionChanged: {
                                            if (drag.active) effect.draggedId = preview.modelData.id;
                                        }
                                    }
                                }
                            }
                            DropGhost {
                                readonly property var plan: view.dropPreview && view.dropPreview.desktopId === desktopRow.modelData.id ? view.dropPreview : null
                                sourceId: effect.draggedId
                                destination: plan ? {
                                    x: desktopRow.stripX(plan.x, plan.columnIndex),
                                    y: plan.y * view.zoom,
                                    width: plan.width * view.zoom,
                                    height: plan.height * view.zoom
                                } : null
                            }
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
                }
            }
        }
        // Live copies of this screen's panels sit exactly over the real ones
        // when closed and slide out toward their edge as the overview opens,
        // so neither end of the transition makes them pop.
        Repeater {
            id: panels
            model: []
            Component.onCompleted: {
                var docks = [];
                var windows = KWin.Workspace.windows;
                for (var i = 0; i < windows.length; ++i) {
                    var w = windows[i];
                    if (w.dock && !w.hidden && w.output && w.output.name === view.screen.name) docks.push(w);
                }
                model = docks;
            }
            delegate: KWin.WindowThumbnail {
                required property var modelData
                readonly property rect area: Qt.rect(modelData.frameGeometry.x - view.screen.geometry.x,
                    modelData.frameGeometry.y - view.screen.geometry.y,
                    modelData.frameGeometry.width, modelData.frameGeometry.height)
                // Slide toward the nearest screen edge, far enough to leave it.
                readonly property var exits: [
                    { gap: area.y + area.height / 2, dx: 0, dy: -(area.y + area.height) },
                    { gap: view.height - area.y - area.height / 2, dx: 0, dy: view.height - area.y },
                    { gap: area.x + area.width / 2, dx: -(area.x + area.width), dy: 0 },
                    { gap: view.width - area.x - area.width / 2, dx: view.width - area.x, dy: 0 }
                ].sort(function(a, b) { return a.gap - b.gap; })
                // Leave a little faster than the zoom so the panel is gone mid-way.
                readonly property real progress: Math.min(1, effect.reveal / Style.panelExit)
                wId: String(modelData.internalId)
                x: area.x + exits[0].dx * progress
                y: area.y + exits[0].dy * progress
                width: area.width
                height: area.height
                z: 50
                opacity: 1 - progress
                visible: progress < 1
            }
        }
        Item {
            id: dragToken
            width: 1; height: 1
            Drag.active: effect.draggedId !== ""
            Drag.keys: ["scrolloverview-window"]
            Drag.hotSpot.x: 0
            Drag.hotSpot.y: 0
            Drag.supportedActions: Qt.MoveAction
            Rectangle {
                width: 180; height: 100
                x: -90; y: -50
                radius: 8
                color: Style.dragTokenColor
                border.color: Style.accent
                border.width: 2
                visible: effect.draggedId !== ""
                KWin.WindowThumbnail { anchors.fill: parent; wId: effect.draggedId }
            }
        }

    }
}
