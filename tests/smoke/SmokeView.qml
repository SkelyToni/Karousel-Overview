import QtQuick
import QtTest

// Per-screen checks for the virtual KWin smoke run (tools/smoke.py), which
// instantiates this inside the overview's screen screenView.
Item {
    required property var screenView
    required property var overview
    required property var rowItems        // the view's desktop row Repeater
    required property var token
    property int extraDelay: 0
    property var openedPreviews: []

    function previews() {
        var items = [];
        for (var i = 0; i < rowItems.count; ++i) {
            var row = rowItems.itemAt(i);
            for (var j = 0; j < row.previewCount; ++j) items.push(row.previewItem(j));
        }
        return items;
    }

    TestCase { id: keys; name: "OverviewKeys"; when: false }

    // The close settles reveal at 0 just before the overview hides.
    Connections {
        target: overview
        function onRevealChanged() {
            if (!overview.closing || overview.reveal !== 0) return;
            for (var i = 0; i < screenView.rows.length; ++i) {
                if (!screenView.rows[i].current) continue;
                var point = rowItems.itemAt(i).viewportOrigin(screenView);
                console.log("SCROLLOVERVIEW-ENDPOINT", Math.abs(point.x) < 0.5 && Math.abs(point.y) < 0.5);
            }
        }
    }
    Timer {
        interval: 50; running: true
        onTriggered: console.log("SCROLLOVERVIEW-VIEW", screenView.rows.length,
            screenView.rows.reduce(function(n, r) { return n + r.windows.length; }, 0))
    }
    Timer {
        interval: 400; running: true
        onTriggered: {
            openedPreviews = previews();
            var row = rowItems.itemAt(0);
            var source = row.previewItem(row.previewCount - 1);
            var target = row.previewItem(row.previewCount - 2);
            var point = target.mapToItem(screenView, target.width / 2, target.height / 2);
            token.x = point.x;
            token.y = point.y;
            overview.draggedId = source.modelData.id;
            checkDrop.restart();
        }
    }
    Timer {
        id: checkDrop
        interval: 32
        onTriggered: {
            console.log("SCROLLOVERVIEW-DROP-PREVIEW", screenView.dropPreview !== null && screenView.dropPreview.stacking &&
                screenView.dropPreview.width > 0 && screenView.dropPreview.height > 0);
            overview.draggedId = "";
            console.log("SCROLLOVERVIEW-DROP-CLEAR", screenView.dropPreview === null);
        }
    }
    Timer {
        interval: 550; running: true
        onTriggered: {
            var previous = screenView.selectedWindow;
            keys.keyClick(Qt.Key_Left);
            console.log("SCROLLOVERVIEW-KEY-LEFT", screenView.selectedWindow !== previous && screenView.selectedWindow !== "");
            var selected = screenView.selectedWindow;
            keys.keyClick(Qt.Key_Right, Qt.MetaModifier);
            console.log("SCROLLOVERVIEW-KEY-MODIFIED", screenView.selectedWindow === selected);
            keys.keyClick(Qt.Key_Down);
            console.log("SCROLLOVERVIEW-KEY-DOWN", screenView.selectedRow === 1 && screenView.selectedWindow === "");
            keys.keyClick(Qt.Key_Up);
            console.log("SCROLLOVERVIEW-KEY-UP", screenView.selectedRow === 0 && screenView.selectedWindow !== "");
            keys.keyClick(Qt.Key_Right);
            console.log("SCROLLOVERVIEW-KEY-RIGHT", screenView.selectedWindow !== selected);
            screenView.centerRow(0);
        }
    }
    property int scrollRow: 0
    Timer {
        id: checkVerticalScroll
        interval: 80
        onTriggered: console.log("SCROLLOVERVIEW-VSCROLL", screenView.selectedRow > scrollRow)
    }
    Timer {
        interval: 700 + extraDelay; running: true
        onTriggered: {
            var row = rowItems.itemAt(screenView.selectedRow);
            var before = row.scrollPosition;
            screenView.scrollAxis(true, -96, screenView.width / 2, screenView.height / 2);
            console.log("SCROLLOVERVIEW-HSCROLL", row.scrollPosition < before);
            scrollRow = screenView.selectedRow;
            screenView.scrollAxis(false, screenView.rowStep, screenView.width / 2, screenView.height / 2);
            checkVerticalScroll.restart();
            // Live previews must survive refreshes rather than be recreated.
            var current = previews();
            var retained = openedPreviews.every(function(item) { return current.indexOf(item) >= 0; });
            console.log("SCROLLOVERVIEW-PREVIEWS", retained ? current.length : -1);
        }
    }
}
