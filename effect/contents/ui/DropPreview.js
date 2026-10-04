.pragma library

// Predict Karousel's column order and equal-height redistribution without
// mutating the live layout. Coordinates remain relative to the target screen.
function plan(rows, draggedId, row, position, stackId, metrics) {
    var sourceRow = null;
    var source = null;
    rows.forEach(function(candidate) {
        candidate.windows.forEach(function(window) {
            if (window.id === draggedId) { source = window; sourceRow = candidate; }
        });
    });
    if (!source || !source.tiled) return null;
    var sourceColumn = sourceRow.columns[source.columnIndex];
    var target = stackId ? row.windows.find(function(window) { return window.id === stackId; }) : null;
    if (stackId && (!target || !target.tiled || target.id === draggedId)) return null;
    if (target && sourceRow.id === row.id && target.columnIndex === source.columnIndex) return null;
    var columns = row.columns.map(function(column, index) {
        return { key: index, width: column.width, changed: false,
            windows: column.windows.map(function(window) { return { id: window.id, height: window.height }; }) };
    });
    var left = Math.max(-1, Math.min(columns.length - 1, position - 1));
    if (sourceRow.id === row.id) {
        if (left === source.columnIndex) left--;
        columns.forEach(function(column) {
            var kept = column.windows.filter(function(window) { return window.id !== draggedId; });
            column.changed = kept.length !== column.windows.length;
            column.windows = kept;
        });
        columns = columns.filter(function(column) { return column.windows.length > 0; });
    }
    var destination;
    if (target) {
        destination = columns.find(function(column) { return column.key === target.columnIndex; });
        destination.windows.push({ id: draggedId, height: source.height });
        destination.changed = true;
    } else {
        destination = { key: -2, width: sourceColumn.windows.length === 1 && sourceRow.id === row.id ?
            sourceColumn.width : metrics.preferredWidth, changed: true,
            windows: [{ id: draggedId, height: metrics.height }] };
        var index = left < 0 ? 0 : columns.findIndex(function(column) { return column.key === left; }) + 1;
        columns.splice(index, 0, destination);
    }
    var x = metrics.left;
    for (var i = 0; i < columns.length; ++i) {
        var column = columns[i];
        if (column === destination) {
            var remaining = metrics.height - metrics.verticalGap * (column.windows.length - 1);
            var y = (metrics.screenHeight - metrics.height) / 2;
            for (var j = 0; j < column.windows.length; ++j) {
                var height = Math.max(1, Math.round(remaining / (column.windows.length - j)));
                if (column.windows[j].id === draggedId)
                    return { desktopId: row.id, x: x, y: y, width: column.width,
                        height: height, columnIndex: i, stacking: !!target };
                remaining -= height;
                y += height + metrics.verticalGap;
            }
        }
        x += column.width + metrics.horizontalGap;
    }
    return null;
}
