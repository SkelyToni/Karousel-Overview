.pragma library

// Layout reads and edits go through the provider that Bridge.js shares with
// Karousel. They live here, inside the versioned effect package, because KWin
// caches Bridge.js by its fixed URL for the compositor's lifetime: changes to
// this file reach a running session on an effect reload.

function windowId(client) { return String(client.internalId); }

function clients(provider) {
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

function snapshot(provider, screen) {
    if (!provider)
        return [];
    var workspace = provider.workspace;
    var world = provider.world;
    var result = [];
    var allWindows = clients(provider);
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
            // Karousel places a column at tilingArea.x - scrollX + gridX, and column.x
            // below already includes the tiling area, so the scroll is the origin.
            row.viewX = layout.getCurrentVisibleRange().getLeft();
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
            // Karousel can scroll until the last column meets the right edge;
            // the overview strip must reach that far to start from the same view.
            row.width = Math.max(row.width, row.viewX + screen.geometry.width);
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

// Karousel's figures that DropPreview.plan needs to place window `id` on
// `desktop`, or null when that desktop has no layout or `id` is not tiled.
function dropMetrics(provider, screen, desktop, id) {
    if (!provider) return null;
    var world = provider.world;
    var layout = world.desktopManager.getDesktopInCurrentActivity(desktop);
    var client = findClient(provider, id);
    var window = client ? world.clientManager.findTiledWindow(client) : null;
    if (!layout || !window) return null;
    return {
        left: layout.tilingArea.x - screen.geometry.x,
        height: layout.tilingArea.height,
        screenHeight: screen.geometry.height,
        horizontalGap: layout.grid.config.gapsInnerHorizontal,
        verticalGap: layout.grid.config.gapsInnerVertical,
        preferredWidth: window.client.preferredWidth
    };
}

function findClient(provider, id) {
    if (!provider) return null;
    var windows = clients(provider);
    for (var i = 0; i < windows.length; ++i)
        if (windowId(windows[i]) === id) return windows[i];
    return null;
}

function focus(provider, id, desktopId) {
    if (!provider) return false;
    var workspace = provider.workspace;
    var desktop = workspace.desktops.find(function(d) { return d.id === desktopId; });
    if (!desktop) return false;
    workspace.currentDesktop = desktop;
    var client = findClient(provider, id);
    if (client) {
        client.minimized = false;
        workspace.activeWindow = client;
    }
    return true;
}

// position is a column boundary; stackId optionally inserts into an existing column.
function move(provider, id, desktopId, position, stackId) {
    if (!provider) return false;
    var workspace = provider.workspace;
    var client = findClient(provider, id);
    var desktop = workspace.desktops.find(function(d) { return d.id === desktopId; });
    if (!client || !desktop) return false;
    provider.world.do(function(clientManager, desktopManager) {
        if (!client.desktops.length || client.desktops.length !== 1 || client.desktops[0].id !== desktop.id)
            client.desktops = [desktop];
        var window = clientManager.findTiledWindow(client);
        var layout = desktopManager.getDesktopInCurrentActivity(desktop);
        if (!window || !layout) return;
        var target = stackId ? clientManager.findTiledWindow(findClient(provider, stackId)) : null;
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
