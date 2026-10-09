import QtQuick
import QtTest
import "../../effect/contents/ui"

Item {
    id: root
    property real reveal: 0
    property int finishedCount: 0
    property real lowest: 0
    property real highest: 0
    onRevealChanged: { lowest = Math.min(lowest, reveal); highest = Math.max(highest, reveal); }
    RevealMotion { id: motion; target: root; onFinished: root.finishedCount++ }
    TestCase {
        name: "RevealMotion"
        function init() {
            motion.reset(0);
            root.finishedCount = 0;
            root.lowest = 0; root.highest = 0;
        }
        function test_opens_and_settles_exactly() {
            motion.animateTo(1);
            verify(motion.running);
            tryCompare(root, "finishedCount", 1, 1000);
            compare(root.reveal, 1);
            verify(root.highest <= 1, "no overshoot");
        }
        function test_fast_release_does_not_overshoot() {
            motion.reset(0.8);
            motion.velocity = 50;
            motion.animateTo(1);
            tryCompare(root, "finishedCount", 1, 1000);
            verify(root.highest <= 1, "release velocity is capped");
        }
        function test_reverses_from_gesture_velocity() {
            motion.reset(0.5);
            motion.velocity = 4;
            motion.animateTo(0);
            tryCompare(root, "finishedCount", 1, 1500);
            verify(root.highest > 0.5, "keeps moving with the fingers before turning back");
            compare(root.reveal, 0);
            verify(root.lowest >= 0);
        }
        function test_tracking_stops_animation() {
            motion.animateTo(1);
            motion.track(0.3);
            verify(!motion.running);
            compare(root.reveal, 0.3);
        }
    }
}
