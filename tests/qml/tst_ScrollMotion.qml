import QtQuick
import QtTest
import "../../effect/contents/ui"

Item {
    width: 800; height: 600
    Flickable {
        id: viewport
        anchors.fill: parent
        contentWidth: 2400; contentHeight: 1800
        Rectangle { width: 2400; height: 1800; color: "#223344" }
        // Mimics previews: wheel input must still work over a clickable child.
        MouseArea { width: 800; height: 600; onClicked: {} }
    }
    ScrollMotion { id: horizontal; viewport: viewport; axis: "contentX"; maximum: 1600 }
    ScrollMotion { id: vertical; viewport: viewport; axis: "contentY"; maximum: 1200; snapStep: 400 }
    Item {
        anchors.fill: parent
        WheelHandler {
            orientation: Qt.Horizontal
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            target: null
            onWheel: function(event) { horizontal.scroll(event.angleDelta.x * 1.8); event.accepted = true; }
        }
        WheelHandler {
            orientation: Qt.Vertical
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            target: null
            onWheel: function(event) { vertical.scroll(event.angleDelta.y * 1.8); event.accepted = true; }
        }
    }
    TestCase {
        name: "ScrollMotion"
        when: windowShown
        function init() {
            horizontal.stop(); vertical.stop();
            viewport.contentX = 0; viewport.contentY = 0;
        }
        function test_horizontal_wheel_over_clickable_child() {
            mouseWheel(viewport, 300, 250, 60, 0);
            verify(viewport.contentX > 0);
            compare(viewport.contentY, 0);
            var immediate = viewport.contentX;
            wait(220);
            verify(viewport.contentX > immediate, "horizontal momentum continues after release");
        }
        function test_vertical_wheel_snaps_to_desktop() {
            mouseWheel(viewport, 300, 250, 0, 120);
            verify(viewport.contentY > 0);
            compare(viewport.contentX, 0);
            tryCompare(viewport, "contentY", 400, 1000);
        }
        function test_boundaries_and_interrupt() {
            horizontal.scroll(10000);
            tryCompare(viewport, "contentX", 1600, 1000);
            horizontal.scroll(-10000);
            tryCompare(viewport, "contentX", 0, 1000);
            horizontal.animateTo(1000);
            wait(50);
            horizontal.pan(-10000);
            wait(350);
            compare(viewport.contentX, 0, "dragging interrupts an in-flight animation");
        }
        function test_keyboard_animation_and_no_spurious_momentum() {
            horizontal.animateTo(800);
            tryCompare(viewport, "contentX", 800, 1000);
            wait(200);
            compare(viewport.contentX, 800);
        }
        function test_accumulated_input_and_stop() {
            horizontal.scroll(50);
            horizontal.scroll(50);
            horizontal.scroll(50);
            compare(horizontal.destination, 225, "input accumulates without losing pending distance");
            verify(viewport.contentX > 0 && viewport.contentX < 225);
            wait(40);
            verify(viewport.contentX > 50, "position follows input between wheel events");
            horizontal.stop();
            var stopped = viewport.contentX;
            wait(400);
            compare(viewport.contentX, stopped, "closing or dragging cancels all pending movement");
        }
        function test_reverse_direction_cancels_pending_distance() {
            horizontal.scroll(100);
            var before = viewport.contentX;
            horizontal.scroll(-10);
            verify(viewport.contentX < before, "reversing follows the fingers immediately");
            verify(horizontal.destination < before, "old forward distance is discarded");
        }
    }
}
