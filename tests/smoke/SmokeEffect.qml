import QtQuick
import org.kde.kwin as KWin
import "../../../scrolloverview/contents/ui/Bridge.js" as Bridge
import "Layout.js" as Layout

// Effect-level script for the virtual KWin smoke run (tools/smoke.py).
// tools/smoke.py copies it into the staged package next to main.qml and
// instantiates it there; it is never installed for real use.
Item {
    required property var overview
    required property var shortcuts
    // Pushes the later steps back so a screenshot can catch the open overview.
    property int extraDelay: 0

    Connections {
        target: shortcuts
        function onBlockedChanged() { console.log("SCROLLOVERVIEW-SHORTCUTS-BLOCKED", shortcuts.blocked); }
    }
    Timer {
        interval: 3500; running: true
        onTriggered: {
            console.log("SCROLLOVERVIEW-BRIDGE", Bridge.ready());
            overview.open();
        }
    }
    Timer {
        interval: 4500 + extraDelay; running: true
        onTriggered: {
            var provider = Bridge.provider;
            var screen = KWin.Workspace.screens[0];
            var rows = Layout.snapshot(provider, screen);
            var moved = rows[0].windows[0].id;
            var stacked = rows[0].windows[1].id;
            Layout.move(provider, moved, rows[0].id, 0, stacked);
            rows = Layout.snapshot(provider, screen);
            console.log("SCROLLOVERVIEW-STACK", rows[0].columns.length);
            Layout.move(provider, moved, rows[0].id, 0, "");
            rows = Layout.snapshot(provider, screen);
            console.log("SCROLLOVERVIEW-SPLIT", rows[0].columns.length);
            Layout.move(provider, moved, rows[1].id, 0, "");
            rows = Layout.snapshot(provider, screen);
            console.log("SCROLLOVERVIEW-MOVE", rows[0].windows.length, rows[1].windows.length);
            Layout.focus(provider, moved, rows[1].id);
            console.log("SCROLLOVERVIEW-FOCUS", KWin.Workspace.currentDesktop.id === rows[1].id);
        }
    }
    Timer {
        interval: 6500 + extraDelay; running: true
        onTriggered: {
            overview.close();
            console.log("SCROLLOVERVIEW-CLOSE");
        }
    }
}
