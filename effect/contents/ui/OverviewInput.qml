import QtQuick
import "Style.js" as Style

// Wheel scrolling, edge scrolling while dragging, and keyboard navigation for
// one screen view. Fill the view with it, above its content: it accepts wheel
// events over previews and empty space while leaving clicks, window dragging
// and Flickable panning to the items below.
Item {
    id: input
    required property var screenView     // the overview's per-screen view
    required property var overview       // the effect
    required property Item token         // drag token shared by the view

    // For the view's Keys.onPressed.
    function handleKey(event) {
        var view = screenView;
        event.accepted = true;
        if (event.key === Qt.Key_Escape) { overview.close(); return; }
        if (event.key === Qt.Key_O && (event.modifiers & Qt.MetaModifier) &&
            (event.modifiers & Qt.ControlModifier)) { overview.close(); return; }
        if (overview.closing || overview.gesturing || event.modifiers !== Qt.NoModifier) return;
        if (event.key === Qt.Key_Left) navigateWindow(-1);
        else if (event.key === Qt.Key_Right) navigateWindow(1);
        else if (event.key === Qt.Key_Up) navigateDesktop(-1);
        else if (event.key === Qt.Key_Down) navigateDesktop(1);
        else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && view.rows.length)
            view.activate(view.selectedWindow, view.rows[view.selectedRow].id);
    }
    // Selects the previous or next window on the selected desktop.
    function navigateWindow(direction) {
        var view = screenView;
        if (!view.rows.length) return;
        var windows = view.rows[view.selectedRow].windows;
        if (!windows.length) { view.selectedWindow = ""; return; }
        var index = windows.findIndex(function(w) { return w.id === view.selectedWindow; });
        index = index < 0 ? (direction < 0 ? windows.length - 1 : 0) :
            Math.max(0, Math.min(windows.length - 1, index + direction));
        view.selectedWindow = windows[index].id;
        var row = view.rowItem(view.selectedRow);
        if (row) row.ensureWindow(windows[index]);
    }
    // Moves to the adjacent desktop and selects the window closest to the
    // horizontal position of the current selection.
    function navigateDesktop(direction) {
        var view = screenView;
        if (!view.rows.length) return;
        var current = view.rows[view.selectedRow];
        var old = current.windows.find(function(window) { return window.id === view.selectedWindow; });
        var center = old ? old.x + old.width / 2 : current.viewX + view.screen.geometry.width / 2;
        view.selectedRow = Math.max(0, Math.min(view.rows.length - 1, view.selectedRow + direction));
        var nearest = null;
        view.rows[view.selectedRow].windows.forEach(function(window) {
            if (!nearest || Math.abs(window.x + window.width / 2 - center) <
                Math.abs(nearest.x + nearest.width / 2 - center)) nearest = window;
        });
        view.selectedWindow = nearest ? nearest.id : "";
        view.centerRow(view.selectedRow, true);
        var row = view.rowItem(view.selectedRow);
        if (row && nearest) row.ensureWindow(nearest);
    }

    WheelHandler {
        orientation: Qt.Horizontal
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        target: null
        onWheel: function(event) {
            input.screenView.scrollAxis(true, event.pixelDelta.x ? -event.pixelDelta.x
                : event.angleDelta.x * Style.wheelAngleScale, event.x, event.y);
            event.accepted = true;
        }
    }
    WheelHandler {
        orientation: Qt.Vertical
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        target: null
        onWheel: function(event) {
            input.screenView.scrollAxis(false, event.pixelDelta.y ? -event.pixelDelta.y
                : event.angleDelta.y * Style.wheelAngleScale, event.x, event.y);
            event.accepted = true;
        }
    }
    // While dragging a window, scroll faster the closer it is to an edge.
    FrameAnimation {
        running: input.overview.draggedId !== ""
        onTriggered: {
            var elapsed = Math.min(40, frameTime * 1000);
            if (elapsed <= 0) return;
            var edge = Style.edgeScroll;
            function push(position, extent, zone, speed) {
                if (position < zone) return -speed * elapsed * Math.min(1, (zone - position) / zone);
                if (position > extent - zone) return speed * elapsed * Math.min(1, (position - extent + zone) / zone);
                return 0;
            }
            var token = input.token;
            var row = input.screenView.rowAt(token.x, token.y);
            var dx = push(token.x, input.width, edge.horizontalZone, edge.horizontalSpeed);
            var dy = push(token.y, input.height, edge.verticalZone, edge.verticalSpeed);
            if (row && dx) row.pan(dx);
            if (dy) input.screenView.panVertical(dy);
        }
    }
}
