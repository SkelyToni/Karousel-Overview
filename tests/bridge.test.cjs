const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const bridge = vm.createContext({ console });
const source = fs.readFileSync(path.join(__dirname, '../effect/contents/ui/Bridge.js'), 'utf8');
vm.runInContext(source.replace(/^\.pragma library\s*/, ''), bridge);

const screen = {name: 'eDP-1', geometry: {x: 0, y: 0, width: 1000, height: 800}};
const desktops = [{id: 'one', name: 'First'}, {id: 'two', name: 'Second'}, {id: 'three', name: 'Empty'}];
function client(id, desktop = desktops[0], options = {}) {
  return {internalId: id, caption: id, normalWindow: true, dialog: false,
    activities: ['activity'], desktops: [desktop], output: screen, minimized: false,
    frameGeometry: {x: 0, y: 0, width: 500, height: 700}, ...options};
}
const a = client('a');
const b = client('b');
const off = client('off', desktops[0], {frameGeometry: {x: 998, y: 0, width: 500, height: 700}});
const floating = client('float', desktops[1]);
const otherActivity = client('other-activity', desktops[0], {activities: ['elsewhere']});
const otherScreen = client('other-screen', desktops[0], {output: {name: 'HDMI-1'}});
const dock = client('dock', desktops[0], {normalWindow: false});
const workspace = {desktops, currentDesktop: desktops[0], currentActivity: 'activity', activeWindow: b,
  windows: [a, b, off, floating, otherActivity, otherScreen, dock]};
function makeColumn(x, clients) {
  const windows = clients.map(c => ({client: {kwinClient: c}, height: 700}));
  const column = {gridX: x, getWidth: () => 500, getFirstWindow: () => windows[0],
    getBelowWindow: win => windows[windows.indexOf(win) + 1], getWindowCount: () => windows.length};
  windows.forEach(w => w.column = column);
  return column;
}
const firstColumn = makeColumn(0, [a, b]);
const lastColumn = makeColumn(1600, [off]);
const columns = [firstColumn, lastColumn];
const grid = {getFirstColumn: () => columns[0], getRightColumn: c => columns[columns.indexOf(c) + 1],
  getLeftColumn: c => columns[columns.indexOf(c) - 1] || null,
  getWidth: () => 2100, config: {gapsInnerVertical: 12}, moveColumn: (column, left) => {
    grid.lastMove = {column, left};
  }};
columns.forEach(c => c.grid = grid);
const layout = {grid, tilingArea: {x: 10, y: 20, width: 980, height: 760},
  getCurrentVisibleRange: () => ({getLeft: () => 600})};
grid.desktop = layout;
const manager = {getDesktopInCurrentActivity: desktop => desktop.id === 'one' ? layout : undefined};
const clientManager = {findTiledWindow: c => {
  for (const column of columns)
    for (let w = column.getFirstWindow(); w; w = column.getBelowWindow(w))
      if (w.client.kwinClient === c) return w;
  return null;
}};
const world = {desktopManager: manager, do: callback => callback(clientManager, manager)};
assert.equal(bridge.ready(), false);
bridge.attach(world, workspace, () => {throw new Error('unexpected new column');});
let rows = bridge.snapshot(screen);
assert.equal(rows.length, 3, 'includes empty desktops');
assert.deepEqual(Array.from(rows, r => r.id), ['one', 'two', 'three']);
assert.deepEqual(Array.from(rows[0].windows, w => w.id), ['a', 'b', 'off'], 'layout order, not geometry or focus order');
assert.equal(rows[0].columns[1].x, 1610, 'off-screen position comes from grid coordinates');
assert.equal(rows[0].viewX, 590);
assert.equal(rows[0].windows[1].focused, true);
assert.ok(rows[0].windows[1].y + rows[0].windows[1].height <= 780.001, 'stacked windows fit the row');
assert.equal(rows[1].floating[0].id, 'float');
const signature = bridge.signature(rows);
assert.equal(bridge.signature(bridge.snapshot(screen)), signature, 'stable snapshot avoids resetting scroll');
a.caption = 'new caption';
assert.notEqual(bridge.signature(bridge.snapshot(screen)), signature);
assert.equal(bridge.focus('float', 'two'), true);
assert.equal(workspace.currentDesktop, desktops[1]);
assert.equal(workspace.activeWindow, floating);
assert.equal(bridge.focus('a', 'missing'), false);
assert.equal(bridge.move('off', 'one', 0, ''), true);
assert.equal(grid.lastMove.column, lastColumn);
assert.equal(grid.lastMove.left, null, 'can reorder to first column');
assert.equal(bridge.move('missing', 'one', 0, ''), false);
bridge.setVisible(true);
assert.equal(bridge.isVisible(), true);
bridge.detach({});
assert.equal(bridge.ready(), true, 'unrelated provider cannot detach the current one');
bridge.detach(world);
assert.equal(bridge.ready(), false);
assert.equal(bridge.snapshot(screen).length, 0);
console.log('Bridge checks passed: desktop order, exact tiling order, off-screen/stacked windows, filters, focus, reorder, lifecycle.');
