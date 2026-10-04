import QtQuick
import org.kde.kwin as KWin

// Global shortcuts run before KWin's effect keyboard grab. Suspend them for
// the modal overview, then restore runtime registrations without changing keys.
Item {
    id: guard
    property bool active: false
    function update(blocked) {
        call.arguments = [blocked];
        call.call();
    }
    onActiveChanged: update(active)
    Component.onDestruction: { if (active) update(false); }
    KWin.DBusCall {
        id: call
        service: "org.kde.kglobalaccel"
        path: "/kglobalaccel"
        dbusInterface: "org.kde.KGlobalAccel"
        method: "blockGlobalShortcuts"
        onFailed: console.warn("Scroll Overview: could not update shortcut inhibition")
    }
}
