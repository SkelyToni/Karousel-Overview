const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const gesture = vm.createContext({});
vm.runInContext(fs.readFileSync('effect/contents/ui/Gesture.js', 'utf8').replace(/^\.pragma library\s*/, ''), gesture);

assert.equal(gesture.reveal(0.25, true, 2), 0.5, 'gain shortens the travel');
assert.equal(gesture.reveal(0.8, true, 2), 1, 'reveal stops at fully open');
assert.equal(gesture.reveal(-0.1, true, 2), 0, 'never below closed');
assert.equal(gesture.reveal(0.25, false, 2), 0.5, 'closing swipes count down from open');
assert.equal(gesture.reveal(1, false, 2), 0);

const complete = (reveal, velocity, opening) => gesture.shouldComplete(reveal, velocity, opening, 0.5, 1.5);
assert.equal(complete(0.6, 0, true), true, 'opening past halfway completes');
assert.equal(complete(0.4, 0, true), false, 'opening short of halfway reverts');
assert.equal(complete(0.2, 2, true), true, 'an upward flick opens from early on');
assert.equal(complete(0.9, -2, true), false, 'flicking back reverts even when nearly open');
assert.equal(complete(0.4, 0, false), true, 'closing past halfway completes');
assert.equal(complete(0.8, -2, false), true, 'a downward flick closes');
assert.equal(complete(0.2, 2, false), false, 'flicking back up keeps the overview open');
console.log('Gesture checks passed: gain, clamping, commit threshold, flicks in both directions.');
