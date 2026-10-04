import QtQuick

// Wheel events in KWin carry libinput axis distance in angleDelta.
// Accumulate input separately from the visible position, then follow it on
// compositor frames so event cadence does not become visible stepping.
Item {
    id: motion
    required property var viewport
    required property string axis
    property real maximum: 0
    property real snapStep: 0
    property real velocity: 0
    property double lastInput: 0
    property real destination: 0
    property bool following: false
    property bool coasting: false
    readonly property real position: viewport ? viewport[axis] : 0
    readonly property bool running: settling.running || frames.running || travel.running
    readonly property bool navigating: travel.running

    function clamp(value) { return Math.max(0, Math.min(Math.max(0, maximum), value)); }
    function stop() {
        settling.stop(); travel.stop();
        following = false; coasting = false;
        velocity = 0;
        lastInput = 0;
        destination = position;
    }
    function pan(delta) {
        stop();
        viewport.cancelFlick();
        viewport[axis] = clamp(position + delta);
        destination = position;
    }
    function scroll(delta) {
        if (!delta) return;
        delta *= 1.5;
        var now = Date.now();
        var elapsed = now - lastInput;
        var reversed = velocity * delta < 0;
        if (!following || coasting || reversed) destination = position;
        if (reversed) velocity = 0;
        coasting = false;
        travel.stop();
        viewport.cancelFlick();
        var instantaneous = delta / (elapsed > 150 ? 16 : Math.max(8, Math.min(50, elapsed)));
        var weight = 1 - Math.exp(-Math.max(8, Math.min(50, elapsed)) / 35);
        velocity = elapsed > 150 || reversed ? instantaneous : velocity * (1 - weight) + instantaneous * weight;
        velocity = Math.max(-1.6, Math.min(1.6, velocity));
        var next = clamp(destination + delta);
        if (next === destination || next === 0 || next === Math.max(0, maximum)) velocity = 0;
        destination = next;
        following = true;
        // A small immediate response keeps the gesture connected to the fingers.
        viewport[axis] = position + (destination - position) * 0.4;
        lastInput = now;
        settling.restart();
    }
    function animateTo(value) {
        stop();
        viewport.cancelFlick();
        travel.from = position;
        travel.to = clamp(value);
        travel.start();
    }
    function finish() {
        if (snapStep > 0) {
            var target = following ? destination : position;
            animateTo(Math.round(clamp(target + velocity * 70) / snapStep) * snapStep);
        } else if (Math.abs(velocity) > 0.04) {
            coasting = true;
            following = true;
        }
    }
    Timer { id: settling; interval: 90; onTriggered: motion.finish() }
    FrameAnimation {
        id: frames
        running: motion.following
        onTriggered: {
            var elapsed = Math.min(50, frameTime * 1000);
            if (elapsed <= 0) return;
            if (motion.coasting) {
                var decay = Math.exp(-elapsed / 190);
                var next = motion.clamp(motion.destination + motion.velocity * 190 * (1 - decay));
                if (next === motion.destination) motion.velocity = 0;
                else motion.velocity *= decay;
                motion.destination = next;
                if (Math.abs(motion.velocity) < 0.025) motion.coasting = false;
            }
            var difference = motion.destination - motion.position;
            if (Math.abs(difference) < 0.1 && !motion.coasting) {
                motion.viewport[motion.axis] = motion.destination;
                motion.following = false;
            } else {
                motion.viewport[motion.axis] = motion.clamp(motion.position + difference * (1 - Math.exp(-elapsed / 18)));
            }
        }
    }
    NumberAnimation {
        id: travel
        target: motion.viewport; property: motion.axis
        duration: Math.max(150, Math.min(340, 150 + Math.abs(to - from) * 0.35))
        easing.type: Easing.OutCubic
    }
    onMaximumChanged: {
        destination = clamp(destination);
        if (viewport && position > maximum) {
            stop(); viewport[axis] = clamp(position);
        }
    }
}
