const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const preview = vm.createContext({});
vm.runInContext(fs.readFileSync('effect/contents/ui/DropPreview.js', 'utf8').replace(/^\.pragma library\s*/, ''), preview);
function row(id, groups) {
  const result = {id, columns: [], windows: []};
  groups.forEach((ids, index) => {
    const column = {x: 10 + index * 520, width: 500, windows: ids.map(id => ({id, tiled: true,
      columnIndex: index, height: 760 / ids.length}))};
    result.columns.push(column); result.windows.push(...column.windows);
  });
  return result;
}
const a = row('a', [['one'], ['two'], ['three']]);
const b = row('b', [['four']]);
const empty = row('empty', []);
const rows = [a, b, empty];
const metrics = {left: 10, height: 760, screenHeight: 800, verticalGap: 12, horizontalGap: 20, preferredWidth: 500};
const before = JSON.stringify(rows);
let result = preview.plan(rows, 'three', a, 0, '', metrics);
assert.equal(result.x, 10);
assert.equal(result.columnIndex, 0);
assert.equal(result.y, 20);
result = preview.plan(rows, 'one', a, 3, '', metrics);
assert.equal(result.x, 1050, 'removing source column adjusts insertion index');
assert.equal(result.columnIndex, 2);
result = preview.plan(rows, 'one', b, 0, 'four', metrics);
assert.equal(result.y, 406, 'stack appends below the existing window after equal redistribution');
assert.equal(result.height, 374);
assert.equal(result.width, 500);
result = preview.plan(rows, 'one', empty, 0, '', metrics);
assert.equal(result.desktopId, 'empty');
assert.equal(result.x, 10);
assert.equal(result.height, 760);
const stack = row('stack', [['top', 'bottom'], ['other']]);
assert.equal(preview.plan([stack], 'top', stack, 0, 'bottom', metrics), null, 'same-column drop is a no-op');
assert.equal(preview.plan(rows, 'missing', a, 0, '', metrics), null);
assert.equal(JSON.stringify(rows), before, 'prediction does not modify the live snapshot');
console.log('Drop preview checks passed: insertion, reorder, stacks, cross-desktop, empty desktops, no-op and no mutation.');
