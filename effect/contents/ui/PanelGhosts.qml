import QtQuick
import org.kde.kwin as KWin
import "Style.js" as Style

// Live copies of an output's panels. They sit exactly over the real ones when
// closed and slide out toward their edge as the overview opens, so neither
// end of the transition makes them pop. Fill the output with this item.
Item {
    id: ghosts
    required property var output
    // Transition progress, 0 closed to 1 open.
    property real progress: 0

    Repeater {
        model: []
        Component.onCompleted: {
            var docks = [];
            var windows = KWin.Workspace.windows;
            for (var i = 0; i < windows.length; ++i) {
                var w = windows[i];
                if (w.dock && !w.hidden && w.output && w.output.name === ghosts.output.name) docks.push(w);
            }
            model = docks;
        }
        delegate: KWin.WindowThumbnail {
            required property var modelData
            readonly property rect area: Qt.rect(modelData.frameGeometry.x - ghosts.output.geometry.x,
                modelData.frameGeometry.y - ghosts.output.geometry.y,
                modelData.frameGeometry.width, modelData.frameGeometry.height)
            // Slide toward the nearest screen edge, far enough to leave it.
            readonly property var exits: [
                { gap: area.y + area.height / 2, dx: 0, dy: -(area.y + area.height) },
                { gap: ghosts.height - area.y - area.height / 2, dx: 0, dy: ghosts.height - area.y },
                { gap: area.x + area.width / 2, dx: -(area.x + area.width), dy: 0 },
                { gap: ghosts.width - area.x - area.width / 2, dx: ghosts.width - area.x, dy: 0 }
            ].sort(function(a, b) { return a.gap - b.gap; })
            // Leave a little faster than the zoom so the panel is gone mid-way.
            readonly property real exit: Math.min(1, ghosts.progress / Style.panelExit)
            wId: String(modelData.internalId)
            x: area.x + exits[0].dx * exit
            y: area.y + exits[0].dy * exit
            width: area.width
            height: area.height
            opacity: 1 - exit
            visible: exit < 1
        }
    }
}
