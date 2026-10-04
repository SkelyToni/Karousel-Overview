import QtQuick
import Qt5Compat.GraphicalEffects
import org.kde.kwin as KWin
import "Bridge.js" as Bridge
import "DropPreview.js" as DropPreview

KWin.SceneEffect {
    id: effect
    property real reveal: 0
    property bool gesturing: false
    property bool gestureStartedOpen: false
    property bool closing: false
    property string draggedId: ""
    property int revision: 0

    ShortcutGuard { active: effect.visible }

    function begin() {
        if (!Bridge.ready()) {
            console.warn("Scroll Overview: restart the patched Karousel script first");
            return false;
        }
        if (!visible) {
            transition.stop();
            closing = false;
            reveal = 0;
            Bridge.setVisible(true);
            visible = true;
        }
        return true;
    }
    function open() {
        if (begin()) {
            transition.stop();
            gesturing = false;
            transition.to = 1;
            transition.duration = Math.max(100, 320 * (1 - reveal));
            transition.restart();
        }
    }
    function prepareClose() {
        if (!closing) closing = true;
    }
    function finishClose() {
        visible = false;
        closing = false;
        draggedId = "";
        Bridge.setVisible(false);
    }
    function close() {
        transition.stop();
        prepareClose();
        gesturing = false;
        if (reveal <= 0) finishClose();
        else {
            transition.to = 0;
            transition.duration = Math.max(100, 320 * reveal);
            transition.restart();
        }
    }
    function toggle() { if (visible) close(); else open(); }

    NumberAnimation {
        id: transition
        target: effect; property: "reveal"
        duration: 320; easing.type: Easing.OutCubic
        onFinished: {
            if (to === 0) effect.finishClose();
            else effect.closing = false;
        }
    }
    Timer {
        interval: 150
        repeat: true
        running: effect.visible && !effect.closing && !effect.draggedId
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
                transition.stop();
                effect.gesturing = true;
            }
            if (!effect.gestureStartedOpen) effect.reveal = progress;
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
            transition.stop();
            effect.prepareClose();
            effect.gesturing = true;
            effect.reveal = 1 - progress;
        }
        onActivated: { if (effect.visible) effect.close(); }
        onCancelled: { if (effect.visible) effect.open(); }
    }
    Connections {
        target: KWin.Workspace
        function onCurrentActivityChanged() { if (effect.visible) effect.close(); }
    }
    Component.onDestruction: Bridge.setVisible(false)
    Component.onCompleted: console.log("Scroll Overview 0.7.0 loaded")

    delegate: FocusScope {
        id: view
        focus: true
        readonly property var screen: KWin.SceneView.screen
        property var rows: []
        readonly property real zoom: 0.48
        readonly property real rowHeight: screen.geometry.height * zoom
        readonly property real rowGap: 64
        readonly property real columnSpacing: 12
        readonly property real columnGapExtra: columnSpacing * effect.reveal
        property int selectedRow: 0
        property string selectedWindow: ""
        property bool initialized: false
        property string rowSignature: ""
        property var scrollPositions: ({})
        property real closingOffsetY: 0
        property var dropPreview: null
        property var dropOwner: null

        function previewDrop(row, position, stackId, owner) {
            if (!effect.draggedId || !Bridge.provider) { dropPreview = null; return; }
            var world = Bridge.provider.world;
            var layout = world.desktopManager.getDesktopInCurrentActivity(row.desktop);
            var client = Bridge.findClient(effect.draggedId);
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
            var next = Bridge.snapshot(screen);
            var nextSignature = Bridge.signature(next);
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
        function centerRow(index, animate) {
            var destination = index * (rowHeight + rowGap);
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
            if (!Bridge.focus(id, desktopId)) return;
            refresh();
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
                if (!effect.closing) return;
                verticalMotion.stop();
                desktops.cancelFlick();
                view.refresh();
                for (var i = 0; i < view.rows.length; ++i) {
                    var row = rowRepeater.itemAt(i);
                    if (row) row.prepareClose();
                    if (view.rows[i].current)
                        view.closingOffsetY = desktops.contentY - i * (view.rowHeight + view.rowGap);
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
                    view.scrollAxis(true, event.pixelDelta.x ? -event.pixelDelta.x : event.angleDelta.x * 1.8, event.x, event.y);
                    event.accepted = true;
                }
            }
            WheelHandler {
                orientation: Qt.Vertical
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                target: null
                onWheel: function(event) {
                    view.scrollAxis(false, event.pixelDelta.y ? -event.pixelDelta.y : event.angleDelta.y * 1.8, event.x, event.y);
                    event.accepted = true;
                }
            }
        }

        ScrollMotion {
            id: verticalMotion
            viewport: desktops; axis: "contentY"
            maximum: desktops.contentHeight - desktops.height
            snapStep: view.rowHeight + view.rowGap
        }
        FrameAnimation {
            running: effect.draggedId !== ""
            onTriggered: {
                var elapsed = Math.min(40, frameTime * 1000);
                if (elapsed <= 0) return;
                var row = view.rowAt(dragToken.x, dragToken.y);
                if (row && dragToken.x < 64) row.pan(-0.7 * elapsed * Math.min(1, (64 - dragToken.x) / 64));
                else if (row && dragToken.x > view.width - 64)
                    row.pan(0.7 * elapsed * Math.min(1, (dragToken.x - view.width + 64) / 64));
                if (dragToken.y < 72) verticalMotion.pan(-0.6 * elapsed * Math.min(1, (72 - dragToken.y) / 72));
                else if (dragToken.y > view.height - 72)
                    verticalMotion.pan(0.6 * elapsed * Math.min(1, (dragToken.y - view.height + 72) / 72));
            }
        }

        // Same wallpaper source and blur radius as Plasma's built-in overview.
        Item {
            anchors.fill: parent
            opacity: effect.reveal
            Rectangle { anchors.fill: parent; color: "#11141c" }
            KWin.DesktopBackground {
                id: wallpaper
                anchors.fill: parent
                activity: KWin.Workspace.currentActivity
                desktop: KWin.Workspace.currentDesktop
                outputName: view.screen.name
                visible: false
            }
            FastBlur { anchors.fill: parent; source: wallpaper; radius: 64 }
            Rectangle { anchors.fill: parent; color: "#11141c"; opacity: 0.45 }
        }
        Flickable {
            id: desktops
            anchors.fill: parent
            anchors.topMargin: 36
            anchors.bottomMargin: 36
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
                        Math.round(contentY / (view.rowHeight + view.rowGap))));
            }
            interactive: !effect.closing && !effect.gesturing
            contentItem.transform: Translate {
                y: effect.closing ? view.closingOffsetY * (1 - effect.reveal) : 0
            }
            transform: Scale {
                origin.x: desktops.width / 2
                origin.y: desktops.height / 2
                xScale: 1 / view.zoom + (1 - 1 / view.zoom) * effect.reveal
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
                        readonly property real inset: Math.max(0, (strip.width - view.screen.geometry.width * view.zoom) / 2)
                        readonly property real originPadding: Math.max(0, -modelData.viewX * view.zoom)
                        function scroll(delta) { horizontalMotion.scroll(delta); }
                        function pan(delta) { horizontalMotion.pan(delta); }
                        function insertionPosition(x) {
                            for (var i = 0; i < modelData.columns.length; ++i) {
                                var column = modelData.columns[i];
                                if (x < (column.x + column.width / 2) * view.zoom + i * view.columnGapExtra) return i;
                            }
                            return modelData.columns.length;
                        }
                        function prepareClose() {
                            horizontalMotion.stop();
                            strip.cancelFlick();
                            closingOffsetX = strip.contentX - (originPadding + modelData.viewX * view.zoom);
                        }
                        function ensureWindow(window) {
                            var center = inset + originPadding + (window.x + window.width / 2) * view.zoom
                                + (window.tiled ? window.columnIndex * view.columnGapExtra : 0);
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
                                opacity: 1 - 0.35 * effect.reveal
                            }
                            Rectangle {
                                anchors.fill: parent
                                color: "transparent"
                                radius: 12 * effect.reveal
                                border.width: effect.reveal
                                border.color: desktopRow.index === view.selectedRow ? "#7287a8" : "#3b4252"
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: view.activate("", desktopRow.modelData.id)
                            }
                        }
                        Flickable {
                            id: strip
                            anchors.fill: parent
                            anchors.leftMargin: 32
                            anchors.rightMargin: 32
                            // Keep clipping stable throughout the zoom; the output clips the scene.
                            clip: false
                            interactive: !effect.closing && !effect.gesturing
                            contentItem.transform: Translate {
                                x: effect.closing ? desktopRow.closingOffsetX * (1 - effect.reveal) : 0
                            }
                            contentWidth: Math.max(width, desktopRow.modelData.width * view.zoom + 2 * desktopRow.inset + desktopRow.originPadding
                                + Math.max(0, desktopRow.modelData.columns.length - 1) * view.columnSpacing)
                            contentHeight: height
                            boundsBehavior: Flickable.StopAtBounds
                            flickableDirection: Flickable.HorizontalFlick
                            Component.onCompleted: {
                                var saved = view.scrollPositions[desktopRow.modelData.id];
                                contentX = Math.max(0, Math.min(contentWidth - width, saved === undefined ?
                                    desktopRow.originPadding + desktopRow.modelData.viewX * view.zoom : saved));
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
                                x: desktopRow.inset + desktopRow.originPadding
                                width: desktopRow.modelData.width * view.zoom
                                    + Math.max(0, desktopRow.modelData.columns.length - 1) * view.columnSpacing
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
                                        view.previewDrop(desktopRow.modelData, desktopRow.insertionPosition(point.x), "", columnDrop);
                                    }
                                    onEntered: updatePreview()
                                    onPositionChanged: updatePreview()
                                    onExited: view.clearDrop(columnDrop)
                                    onDropped: function(drop) {
                                        var position = desktopRow.insertionPosition(drop.x);
                                        Bridge.move(effect.draggedId, desktopRow.modelData.id, position, "");
                                        view.clearDrop(columnDrop);
                                        drop.acceptProposedAction();
                                    }
                                }
                            }
                            Repeater {
                                model: desktopRow.renderedWindows.length
                                delegate: Item {
                                    id: preview
                                    required property int index
                                    readonly property var modelData: desktopRow.renderedWindows[index]
                                    readonly property bool animateGeometry: effect.reveal > 0.99 && !effect.closing && !effect.draggedId
                                    x: desktopRow.inset + desktopRow.originPadding + modelData.x * view.zoom
                                        + (modelData.tiled ? modelData.columnIndex * view.columnGapExtra : 0)
                                    // Center each complete column in the wallpaper during
                                    // overview, then restore desktop coordinates for closing.
                                    y: (modelData.y + (modelData.tiled ? desktopRow.verticalOffsets[modelData.columnIndex] || 0 : 0)
                                        * effect.reveal) * view.zoom
                                    width: modelData.width * view.zoom
                                    height: modelData.height * view.zoom
                                    z: modelData.tiled ? 1 : 2
                                    Behavior on x { enabled: preview.animateGeometry; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                                    Behavior on y { enabled: preview.animateGeometry; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                                    Behavior on width { enabled: preview.animateGeometry; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                                    Behavior on height { enabled: preview.animateGeometry; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                                    Rectangle {
                                        anchors.fill: parent
                                        anchors.margins: preview.modelData.id === view.selectedWindow ? -4 * effect.reveal : 0
                                        radius: 7 * effect.reveal
                                        color: "#181c25"
                                        border.width: preview.modelData.id === view.selectedWindow ? 4 * effect.reveal : 0
                                        border.color: "#78a7ff"
                                    }
                                    KWin.WindowThumbnail {
                                        anchors.fill: parent
                                        wId: preview.modelData.id
                                        opacity: effect.draggedId === preview.modelData.id ? 0.5 : 1
                                        Behavior on opacity { NumberAnimation { duration: 100 } }
                                    }
                                    Rectangle {
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.bottom: parent.bottom
                                        height: 25
                                        color: "#cc141821"
                                        opacity: effect.reveal * (previewMouse.containsMouse || preview.modelData.id === view.selectedWindow ? 1 : 0)
                                        Behavior on opacity { NumberAnimation { duration: 120 } }
                                        Text {
                                            anchors.fill: parent
                                            anchors.margins: 5
                                            text: preview.modelData.caption
                                            elide: Text.ElideRight
                                            color: "#eef0f5"
                                            font.pixelSize: 11
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
                                                Bridge.move(effect.draggedId, desktopRow.modelData.id,
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
                                    x: desktopRow.inset + desktopRow.originPadding + plan.x * view.zoom + plan.columnIndex * view.columnGapExtra,
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
                color: "#26324a"
                border.color: "#78a7ff"
                border.width: 2
                visible: effect.draggedId !== ""
                KWin.WindowThumbnail { anchors.fill: parent; wId: effect.draggedId }
            }
        }

    }
}
