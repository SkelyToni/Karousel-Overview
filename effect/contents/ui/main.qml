import QtQuick
import org.kde.kwin as KWin
// Only this file may import Bridge.js: the installer points this import at
// the copy shared with Karousel, and other files would get a private copy.
import "Bridge.js" as Bridge
import "Layout.js" as Layout
import "DropPreview.js" as DropPreview
import "Style.js" as Style

KWin.SceneEffect {
    id: effect
    // Lifecycle: begin() shows the effect at reveal 0; open() and close()
    // animate reveal with RevealMotion, while gestures drive it directly
    // (gesturing). `closing` is set by the first closing step and stays set
    // until the next begin(); the view uses it to aim the camera at the
    // destination (see the view's beginClosing()).
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
        // Prepares the camera to zoom into Karousel's view of the current
        // desktop. The steps depend on each other, in this order:
        // 1. Lock preview geometry first, so the refresh in step 3 moves
        //    previews instantly instead of starting slides mid-zoom.
        // 2. Stop all scrolling and note where each strip sits on screen.
        // 3. Refresh: focusing a window made Karousel rescroll, which can
        //    change a row's origin padding.
        // 4. Put each strip back where it was on screen and aim the closing
        //    pan at Karousel's view; the camera then follows effect.reveal.
        function beginClosing() {
            geometryLocked = true;
            verticalMotion.stop();
            desktops.cancelFlick();
            var captured = [];
            for (var j = 0; j < rowRepeater.count; ++j) {
                var shown = rowRepeater.itemAt(j);
                captured.push(shown ? shown.captureScroll() : null);
            }
            refresh();
            for (var i = 0; i < rows.length; ++i) {
                var row = rowRepeater.itemAt(i);
                if (row) row.prepareClose(captured[i]);
                if (rows[i].current) closingOffsetY = desktops.contentY - rowContentY(i);
            }
        }
        function moveWindow(id, desktopId, position, stackId) {
            Layout.move(Bridge.provider, id, desktopId, position, stackId);
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
                if (effect.closing) view.beginClosing();
                else view.geometryLocked = false;
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

        Backdrop {
            anchors.fill: parent
            // Keep the wallpaper the overview opened from, see openedDesktop.
            desktop: effect.openedDesktop
            outputName: view.screen.name
            progress: effect.reveal
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
                    delegate: DesktopRow {
                        width: rowColumn.width
                        height: view.rowHeight
                        screenView: view
                        overview: effect
                        token: dragToken
                    }
                }
            }
        }
        PanelGhosts {
            anchors.fill: parent
            z: 50
            output: view.screen
            progress: effect.reveal
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
