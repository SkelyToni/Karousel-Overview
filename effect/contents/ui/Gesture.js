.pragma library

// Touchpad swipe handling. KWin reports a swipe's progress from 0 to 1, where
// 1 is a fixed travel across the touchpad, and reports the swipe as finished
// only once progress reaches 1; any earlier release arrives as cancelled.

// Reveal for swipe progress, reaching the end after 1 / gain of the travel.
function reveal(progress, opening, gain) {
    var travelled = Math.min(1, Math.max(0, progress) * gain);
    return opening ? travelled : 1 - travelled;
}

// Whether a released swipe should complete its transition instead of
// reverting. A flick decides by direction; otherwise the swipe completes
// once it got past `commit` of the way. Velocity is in reveal per second.
function shouldComplete(reveal, velocity, opening, commit, flickVelocity) {
    var progress = opening ? reveal : 1 - reveal;
    var speed = opening ? velocity : -velocity;
    if (speed >= flickVelocity) return true;
    if (speed <= -flickVelocity) return false;
    return progress >= commit;
}
