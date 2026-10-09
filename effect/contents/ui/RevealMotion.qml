import QtQuick

// Drives the overview's reveal progress with a critically damped spring.
// Animations start from the current value and velocity, so a released
// gesture or an interrupted transition continues without a visible kink.
Item {
    id: motion
    required property QtObject target
    // Angular frequency in 1/s; settles within 1% in about 6.6 / stiffness seconds.
    property real stiffness: 19
    property real velocity: 0
    property real to: 0
    property double lastSample: 0
    // Gesture samples older than this no longer describe the fingers' speed.
    property int staleAfterMs: 100
    readonly property bool running: frames.running
    readonly property real value: target ? target.reveal : 0
    signal finished()

    function stop() { frames.running = false; }
    function track(next) {
        // Follow the fingers while measuring their speed for the handoff.
        stop();
        var now = Date.now();
        var elapsed = now - lastSample;
        var instantaneous = lastSample && elapsed > 0 ? (next - value) / (elapsed / 1000) : 0;
        var weight = elapsed > 120 ? 1 : 1 - Math.exp(-Math.max(1, elapsed) / 40);
        velocity = velocity * (1 - weight) + instantaneous * weight;
        lastSample = now;
        target.reveal = next;
    }
    // Finger speed at release; a gesture that paused before release has none.
    function releaseVelocity() {
        return lastSample && Date.now() - lastSample > staleAfterMs ? 0 : velocity;
    }
    function animateTo(destination) {
        to = destination;
        velocity = releaseVelocity();
        lastSample = 0;
        // Approach monotonically: velocity toward the destination larger than
        // stiffness * distance would overshoot, so the release is capped there.
        var distance = destination - value;
        var limit = stiffness * Math.abs(distance);
        if (velocity * distance > 0) velocity = Math.max(-limit, Math.min(limit, velocity));
        else velocity = Math.max(-4, Math.min(4, velocity));
        if (Math.abs(distance) < 0.0005 && Math.abs(velocity) < 0.01) settle();
        else frames.running = true;
    }
    function settle() {
        frames.running = false;
        velocity = 0;
        target.reveal = to;
        finished();
    }
    function reset(next) {
        stop();
        velocity = 0;
        lastSample = 0;
        target.reveal = next;
    }

    FrameAnimation {
        id: frames
        onTriggered: {
            var dt = Math.min(0.05, frameTime);
            if (dt <= 0) return;
            var omega = motion.stiffness;
            var offset = motion.value - motion.to;
            var c = motion.velocity + omega * offset;
            var decay = Math.exp(-omega * dt);
            var nextOffset = (offset + c * dt) * decay;
            motion.velocity = (c - omega * (offset + c * dt)) * decay;
            if (Math.abs(nextOffset) < 0.001 && Math.abs(motion.velocity) < 0.02) motion.settle();
            else motion.target.reveal = motion.to + nextOffset;
        }
    }
}
