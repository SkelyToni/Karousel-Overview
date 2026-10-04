.pragma library

// Declarative effects and scripts share Scripting::qmlEngine() in KWin 6.6.
// Both imports MUST resolve to this same file URL for this state to be shared.
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

function windowId(client) { return String(client.internalId); }

function clients() {
    var result = [];
    if (provider)
        for (var i = 0; i < provider.workspace.windows.length; ++i)
            result.push(provider.workspace.windows[i]);
    return result;
}

function belongs(client, desktop, activity, screenName) {
    return (client.normalWindow || client.dialog) &&
        (!client.activities.length || client.activities.indexOf(activity) >= 0) &&
        (!client.desktops.length || client.desktops.some(function(d) { return d.id === desktop.id; })) &&
        client.output && client.output.name === screenName;
}

function snapshot(screen) {
    if (!provider)
        return [];
    var workspace = provider.workspace;
    var world = provider.world;
    var result = [];
    var allWindows = clients();
    var activeId = workspace.activeWindow ? windowId(workspace.activeWindow) : "";
    for (var i = 0; i < workspace.desktops.length; ++i) {
        var desktop = workspace.desktops[i];
        var layout = world.desktopManager.getDesktopInCurrentActivity(desktop);
        var area = layout ? layout.tilingArea : screen.geometry;
        var row = {
            id: desktop.id, desktop: desktop, name: desktop.name,
            current: workspace.currentDesktop.id === desktop.id,
            width: screen.geometry.width, height: screen.geometry.height,
            viewX: 0, columns: [], floating: [], windows: []
        };
        var included = {};
        if (layout) {
            var grid = layout.grid;
            row.viewX = layout.getCurrentVisibleRange().getLeft() - area.x + screen.geometry.x;
            for (var col = grid.getFirstColumn(); col; col = grid.getRightColumn(col)) {
                var column = { x: col.gridX + area.x - screen.geometry.x,
                    width: col.getWidth(), windows: [] };
                var y = area.y - screen.geometry.y;
                var entries = [];
                for (var win = col.getFirstWindow(); win; win = col.getBelowWindow(win)) {
                    var client = win.client.kwinClient;
                    if (!belongs(client, desktop, workspace.currentActivity, screen.name))
                        continue;
                    entries.push({ client: client, height: win.height });
                }
                // Reveal each stacked window in its stored order in the overview.
                var gap = grid.config.gapsInnerVertical;
                var total = entries.reduce(function(sum, entry) { return sum + entry.height; }, 0);
                var factor = Math.min(1, Math.max(1, area.height - gap * Math.max(0, entries.length - 1)) / Math.max(1, total));
                entries.forEach(function(entry) {
                    var id = windowId(entry.client);
                    var item = { id: id, client: entry.client, caption: entry.client.caption,
                        x: column.x, y: y, width: column.width,
                        height: Math.max(1, entry.height * factor), focused: id === activeId,
                        tiled: true, columnIndex: row.columns.length };
                    y += item.height + gap;
                    included[id] = true;
                    column.windows.push(item);
                    row.windows.push(item);
                });
                if (column.windows.length)
                    row.columns.push(column);
            }
            row.width = Math.max(row.width, grid.getWidth() + area.x - screen.geometry.x + 24);
        }
        allWindows.forEach(function(client) {
            var id = windowId(client);
            if (included[id] || !belongs(client, desktop, workspace.currentActivity, screen.name))
                return;
            var geometry = client.frameGeometry;
            var item = { id: id, client: client, caption: client.caption,
                x: geometry.x - screen.geometry.x + row.viewX,
                y: geometry.y - screen.geometry.y,
                width: geometry.width, height: geometry.height,
                focused: id === activeId, tiled: false, columnIndex: -1 };
            row.floating.push(item);
            row.windows.push(item);
            row.width = Math.max(row.width, item.x + item.width + 24);
        });
        result.push(row);
    }
    return result;
}

function signature(rows) {
    return JSON.stringify(rows.map(function(row) {
        return [row.id, row.name, row.current, row.width, row.height, row.viewX,
            row.windows.map(function(w) {
                return [w.id, w.caption, w.x, w.y, w.width, w.height, w.focused, w.tiled, w.columnIndex];
            })];
    }));
}

function findClient(id) {
    if (!provider) return null;
    var windows = clients();
    for (var i = 0; i < windows.length; ++i)
        if (windowId(windows[i]) === id) return windows[i];
    return null;
}

function focus(id, desktopId) {
    if (!provider) return false;
    var workspace = provider.workspace;
    var desktop = workspace.desktops.find(function(d) { return d.id === desktopId; });
    if (!desktop) return false;
    workspace.currentDesktop = desktop;
    var client = findClient(id);
    if (client) {
        client.minimized = false;
        workspace.activeWindow = client;
    }
    return true;
}

// position is a column boundary; stackId optionally inserts into an existing column.
function move(id, desktopId, position, stackId) {
    if (!provider) return false;
    var workspace = provider.workspace;
    var client = findClient(id);
    var desktop = workspace.desktops.find(function(d) { return d.id === desktopId; });
    if (!client || !desktop) return false;
    provider.world.do(function(clientManager, desktopManager) {
        if (!client.desktops.length || client.desktops.length !== 1 || client.desktops[0].id !== desktop.id)
            client.desktops = [desktop];
        var window = clientManager.findTiledWindow(client);
        var layout = desktopManager.getDesktopInCurrentActivity(desktop);
        if (!window || !layout) return;
        var target = stackId ? clientManager.findTiledWindow(findClient(stackId)) : null;
        if (target && target !== window && target.column.grid === layout.grid) {
            window.moveToColumn(target.column, true, 0); // FocusPassing.Type.None
            return;
        }
        var grid = layout.grid;
        var left = null;
        var count = 0;
        for (var column = grid.getFirstColumn(); column; column = grid.getRightColumn(column)) {
            if (count++ >= position) break;
            left = column;
        }
        if (left === window.column) left = grid.getLeftColumn(left);
        if (window.column.getWindowCount() === 1 && window.column.grid === grid)
            grid.moveColumn(window.column, left);
        else
            window.moveToColumn(provider.createColumn(grid, left), true, 0);
    });
    return true;
}
