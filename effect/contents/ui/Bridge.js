.pragma library

// Declarative effects and scripts share Scripting::qmlEngine() in KWin 6.6.
// Both imports MUST resolve to this same file URL for this state to be shared.
// The engine keeps this file cached for the compositor's lifetime, so a
// running session never sees edits here; keep it to shared state only and
// put logic in Layout.js.
var provider = null;
var overviewVisible = false;

function attach(world, workspace, createColumn) {
    provider = { world: world, workspace: workspace, createColumn: createColumn };
}

function detach(world) {
    if (provider && provider.world === world)
        provider = null;
}

function ready() { return provider !== null; }
function setVisible(value) { overviewVisible = value; }
function isVisible() { return overviewVisible; }
