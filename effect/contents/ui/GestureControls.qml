import QtQuick
import org.kde.kwin as KWin
import "Gesture.js" as Gesture
import "Style.js" as Style

// Four-finger swipes: up opens the overview, down closes it, both following
// the fingers. A swipe released early completes or reverts by Gesture.js
// instead of always reverting, which KWin's cancellation would imply.
Item {
    id: controls
    required property var overview      // the effect
    required property var motion        // its RevealMotion
    // An upward swipe that began with the overview already open is ignored.
    property bool startedOpen: false

    function release(opening) {
        var complete = Gesture.shouldComplete(overview.reveal, motion.releaseVelocity(), opening,
            Style.gestureCommit, Style.gestureFlick);
        if (complete === opening) overview.open();
        else overview.close();
    }
    function end() {
        overview.gesturing = false;
        startedOpen = false;
    }

    KWin.SwipeGestureHandler {
        direction: KWin.SwipeGestureHandler.Direction.Up
        fingerCount: 4
        onProgressChanged: {
            if (!controls.overview.gesturing) {
                controls.startedOpen = controls.overview.visible;
                if (controls.startedOpen || !controls.overview.begin()) return;
                controls.overview.gesturing = true;
            }
            if (!controls.startedOpen)
                controls.motion.track(Gesture.reveal(progress, true, Style.gestureGain));
        }
        onActivated: {
            if (!controls.startedOpen) controls.overview.open();
            controls.end();
        }
        onCancelled: {
            if (controls.overview.gesturing && !controls.startedOpen) controls.release(true);
            controls.end();
        }
    }
    KWin.SwipeGestureHandler {
        direction: KWin.SwipeGestureHandler.Direction.Down
        fingerCount: 4
        onProgressChanged: {
            if (!controls.overview.visible) return;
            controls.overview.prepareClose();
            controls.overview.gesturing = true;
            controls.motion.track(Gesture.reveal(progress, false, Style.gestureGain));
        }
        onActivated: { if (controls.overview.visible) controls.overview.close(); }
        onCancelled: { if (controls.overview.visible) controls.release(false); }
    }
}
