#!/usr/bin/env python3
"""Load the effect in a separate virtual KWin under dbus-run-session."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--karousel", type=Path, required=True)
    parser.add_argument("--kwin", default="kwin_wayland")
    parser.add_argument("--qml", default="qml")
    parser.add_argument("--log", type=Path, default=Path("/tmp/scrolloverview-smoke.log"))
    parser.add_argument("--screenshot", type=Path, help="Save a rendered overview frame for visual inspection")
    parser.add_argument("--hot-reload", action="store_true", help="Verify that a running compositor loads changed QML after an effect reload")
    args = parser.parse_args()
    processes = []
    with tempfile.TemporaryDirectory(prefix="scrolloverview-smoke-") as temporary:
        temp = Path(temporary)
        env = os.environ.copy()
        for name, directory in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                                ("XDG_CACHE_HOME", "cache"), ("XDG_RUNTIME_DIR", "runtime")]:
            path = temp / directory
            path.mkdir(mode=0o700)
            env[name] = str(path)
        env["WAYLAND_DISPLAY"] = "scrolloverview-test"
        env["KWIN_COMPOSE"] = "O2"
        env["LIBGL_ALWAYS_SOFTWARE"] = "1"
        env["QT_FORCE_STDERR_LOGGING"] = "1"
        env["QT_LOGGING_TO_CONSOLE"] = "1"
        env["QT_LOGGING_RULES"] = "kwin_core.debug=true;qml.debug=true"
        env["QML_DISABLE_DISK_CACHE"] = "1"
        env.pop("DISPLAY", None)
        # Karousel only tiles windows belonging to exactly one KDE activity.
        qdbus = shutil.which("qdbus6") or shutil.which("qdbus")
        if not qdbus:
            raise RuntimeError("qdbus is needed to start the isolated activity manager")
        activity = subprocess.run([qdbus, "org.kde.ActivityManager", "/ActivityManager/Activities",
                                   "CurrentActivity"], env=env, capture_output=True, text=True, timeout=15)
        if activity.returncode:
            raise RuntimeError("Could not initialize isolated activities: " + activity.stderr)
        package = temp / "data/kwin/scripts/karousel"
        shutil.copytree(args.karousel, package)
        for path in [package, *package.rglob("*")]:
            path.chmod(0o755 if path.is_dir() else 0o644)
        subprocess.run([sys.executable, str(ROOT / "tools/install.py"), "install",
                        "--data-home", str(temp / "data")], check=True, env=env)
        plugin_id = json.loads((package / ".scrolloverview-backup/manifest.json").read_text())["effect_id"]
        (temp / "config/kwinrc").write_text(f"""[Desktops]
Number=3
Rows=3
Name_1=First
Name_2=Second
Name_3=Third
[Plugins]
karouselEnabled=true
overviewEnabled=false
{plugin_id}Enabled=true
[Compositing]
GLCore=true
""")
        # Instrument only the staged test copy; do not change the shipping effect.
        main_qml = temp / "data/kwin/effects" / plugin_id / "contents/ui/main.qml"
        source = main_qml.read_text().replace("import QtQuick\n", "import QtQuick\nimport QtTest\n", 1)
        source = source.replace("    id: effect", """    id: effect
    Timer {
        interval: 3500; running: true
        onTriggered: {
            console.log("SCROLLOVERVIEW-BRIDGE", Bridge.ready());
            effect.open();
        }
    }
    Timer {
        interval: 4500; running: true
        onTriggered: {
            var screen = KWin.Workspace.screens[0];
            var rows = Layout.snapshot(Bridge.provider, screen);
            var moved = rows[0].windows[0].id;
            var stacked = rows[0].windows[1].id;
            Layout.move(Bridge.provider, moved, rows[0].id, 0, stacked);
            rows = Layout.snapshot(Bridge.provider, screen);
            console.log("SCROLLOVERVIEW-STACK", rows[0].columns.length);
            Layout.move(Bridge.provider, moved, rows[0].id, 0, "");
            rows = Layout.snapshot(Bridge.provider, screen);
            console.log("SCROLLOVERVIEW-SPLIT", rows[0].columns.length);
            Layout.move(Bridge.provider, moved, rows[1].id, 0, "");
            rows = Layout.snapshot(Bridge.provider, screen);
            console.log("SCROLLOVERVIEW-MOVE", rows[0].windows.length, rows[1].windows.length);
            Layout.focus(Bridge.provider, moved, rows[1].id);
            console.log("SCROLLOVERVIEW-FOCUS", KWin.Workspace.currentDesktop.id === rows[1].id);
        }
    }
    Timer {
        interval: 6500; running: true
        onTriggered: {
            effect.close();
            console.log("SCROLLOVERVIEW-CLOSE");
        }
    }
""", 1)
        source = source.replace("    function finishClose() {", "    signal testClosingEndpoint()\n    function finishClose() {\n        testClosingEndpoint();")
        source = source.replace("        property var scrollPositions: ({})", """        property var scrollPositions: ({})
        Connections {
            target: effect
            function onTestClosingEndpoint() {
                for (var i = 0; i < view.rows.length; ++i) {
                    if (!view.rows[i].current) continue;
                    var point = rowRepeater.itemAt(i).testViewportOrigin();
                    console.log("SCROLLOVERVIEW-ENDPOINT", effect.reveal === 0 && Math.abs(point.x) < 0.5 && Math.abs(point.y) < 0.5);
                }
            }
        }""")
        source = source.replace("                        function holdScroll() {", """                        function testViewportOrigin() {
                            return strip.contentItem.mapToItem(view, inset + originPadding + modelData.viewX * view.zoom, 0);
                        }
                        function holdScroll() {""")
        source = source.replace("Component.onCompleted: { refresh(); forceActiveFocus(); }",
                                '''TestCase { id: keyboardTest; name: "OverviewKeys"; when: false }
        Timer {
            interval: 400; running: true
            onTriggered: {
                var row = rowRepeater.itemAt(0);
                row.testBeginDrop();
                checkDrop.restart();
            }
        }
        Timer {
            id: checkDrop
            interval: 32
            onTriggered: {
                console.log("SCROLLOVERVIEW-DROP-PREVIEW", view.dropPreview !== null && view.dropPreview.stacking &&
                    view.dropPreview.width > 0 && view.dropPreview.height > 0);
                effect.draggedId = "";
                console.log("SCROLLOVERVIEW-DROP-CLEAR", view.dropPreview === null);
            }
        }
        Timer {
            interval: 550; running: true
            onTriggered: {
                var previous = view.selectedWindow;
                keyboardTest.keyClick(Qt.Key_Left);
                console.log("SCROLLOVERVIEW-KEY-LEFT", view.selectedWindow !== previous && view.selectedWindow !== "");
                var selected = view.selectedWindow;
                keyboardTest.keyClick(Qt.Key_Right, Qt.MetaModifier);
                console.log("SCROLLOVERVIEW-KEY-MODIFIED", view.selectedWindow === selected);
                keyboardTest.keyClick(Qt.Key_Down);
                console.log("SCROLLOVERVIEW-KEY-DOWN", view.selectedRow === 1 && view.selectedWindow === "");
                keyboardTest.keyClick(Qt.Key_Up);
                console.log("SCROLLOVERVIEW-KEY-UP", view.selectedRow === 0 && view.selectedWindow !== "");
                keyboardTest.keyClick(Qt.Key_Right);
                console.log("SCROLLOVERVIEW-KEY-RIGHT", view.selectedWindow !== selected);
                view.centerRow(0);
            }
        }
        property int createdPreviews: 0
        property int oldScrollRow: 0
        Timer {
            id: checkVerticalScroll
            interval: 80
            onTriggered: console.log("SCROLLOVERVIEW-VSCROLL", view.selectedRow > view.oldScrollRow)
        }
        Timer {
            interval: 700; running: true
            onTriggered: {
                var row = rowRepeater.itemAt(view.selectedRow);
                var before = row.scrollPosition;
                view.scrollAxis(true, -96, view.width / 2, view.height / 2);
                console.log("SCROLLOVERVIEW-HSCROLL", row.scrollPosition < before);
                view.oldScrollRow = view.selectedRow;
                view.scrollAxis(false, view.rowHeight + view.rowGap, view.width / 2, view.height / 2);
                checkVerticalScroll.restart();
                console.log("SCROLLOVERVIEW-PREVIEWS", view.createdPreviews);
            }
        }
        Component.onCompleted: { refresh(); forceActiveFocus(); console.log("SCROLLOVERVIEW-VIEW", rows.length, rows.reduce(function(n,r) { return n+r.windows.length; },0)); }''')
        source = source.replace("model: desktopRow.renderedWindows.length", "id: smokeWindowRepeater\n                                model: desktopRow.renderedWindows.length", 1)
        source = source.replace("                        function holdScroll() {", """                        function testBeginDrop() {
                            var source = smokeWindowRepeater.itemAt(smokeWindowRepeater.count - 1);
                            var target = smokeWindowRepeater.itemAt(smokeWindowRepeater.count - 2);
                            var point = target.mapToItem(view, target.width / 2, target.height / 2);
                            dragToken.x = point.x;
                            dragToken.y = point.y;
                            effect.draggedId = source.modelData.id;
                        }
                        function holdScroll() {""", 1)
        source = source.replace("id: preview", "id: preview\n                                    Component.onCompleted: view.createdPreviews++", 1)
        if args.screenshot:
            args.screenshot.parent.mkdir(parents=True, exist_ok=True)
            source = source.replace("interval: 700;", "interval: 2700;")
            source = source.replace("interval: 4500;", "interval: 6500;")
            source = source.replace("interval: 6500; running: true\n        onTriggered: {\n            effect.close();", "interval: 8500; running: true\n        onTriggered: {\n            effect.close();")
        main_qml.write_text(source)
        guard_qml = main_qml.parent / "ShortcutGuard.qml"
        guard_qml.write_text(guard_qml.read_text().replace(
            '        onFailed:', '        onFinished: console.log("SCROLLOVERVIEW-SHORTCUTS-BLOCKED", call.arguments[0])\n        onFailed:', 1))
        client_qml = temp / "client.qml"
        client_qml.write_text("""import QtQuick
import QtQuick.Window
Window {
    visible: true; width: 650; height: 600
    title: "Scroll Overview smoke client"
    color: "#29354a"
    Text { anchors.centerIn: parent; text: "Live preview test"; color: "white"; font.pixelSize: 36 }
}
""")
        with args.log.open("w") as log:
            try:
                processes.append(subprocess.Popen([args.kwin, "--virtual", "--width", "1280", "--height", "800",
                                                    "--no-lockscreen", "--socket", "scrolloverview-test"],
                                                   env=env, stdout=log, stderr=log))
                socket = temp / "runtime/scrolloverview-test"
                deadline = time.monotonic() + 12
                while not socket.exists() and processes[0].poll() is None and time.monotonic() < deadline:
                    time.sleep(0.1)
                if not socket.exists():
                    raise RuntimeError("Virtual KWin did not start; inspect the smoke log")
                for _ in range(4):
                    processes.append(subprocess.Popen([args.qml, "-platform", "wayland", str(client_qml)],
                                                       env=env, stdout=log, stderr=log))
                if args.screenshot:
                    time.sleep(5.6)
                    processes.append(subprocess.Popen(["spectacle", "--background", "--nonotify", "--fullscreen",
                                                       "--output", str(args.screenshot.resolve())],
                                                      env=env, stdout=log, stderr=log))
                    time.sleep(4.4)
                else:
                    deadline = time.monotonic() + 12
                    while "SCROLLOVERVIEW-BRIDGE true" not in args.log.read_text() and time.monotonic() < deadline:
                        time.sleep(0.1)
                    time.sleep(0.7)
                    time.sleep(18.9 if args.hot_reload else 3.9)
                if args.hot_reload:
                    source_root = temp / "update-source"
                    (source_root / "tools").mkdir(parents=True)
                    shutil.copy(ROOT / "tools/install.py", source_root / "tools/install.py")
                    shutil.copytree(ROOT / "effect", source_root / "effect")
                    updated_main = source_root / "effect/contents/ui/main.qml"
                    updated_main.write_text(updated_main.read_text().replace("Scroll Overview 0.7.0 loaded", "Scroll Overview hotreload loaded"))
                    subprocess.run([sys.executable, str(source_root / "tools/install.py"), "install",
                                    "--data-home", str(temp / "data"), "--reload-effect"], env=env,
                                   stdout=log, stderr=log, check=True, timeout=10)
                    time.sleep(1)
            finally:
                for process in reversed(processes):
                    if process.poll() is None:
                        process.terminate()
                for process in processes:
                    try:
                        process.wait(timeout=4)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
        output = args.log.read_text()
        if "SCROLLOVERVIEW-BRIDGE true" not in output or "SCROLLOVERVIEW-VIEW 3 4" not in output:
            raise RuntimeError(f"Overview smoke markers missing; inspect {args.log}")
        for marker in ["SCROLLOVERVIEW-STACK 3", "SCROLLOVERVIEW-SPLIT 4",
                       "SCROLLOVERVIEW-MOVE 3 1", "SCROLLOVERVIEW-FOCUS true", "SCROLLOVERVIEW-CLOSE",
                       "SCROLLOVERVIEW-HSCROLL true", "SCROLLOVERVIEW-VSCROLL true", "SCROLLOVERVIEW-PREVIEWS 4", "SCROLLOVERVIEW-ENDPOINT true", "SCROLLOVERVIEW-DROP-PREVIEW true", "SCROLLOVERVIEW-DROP-CLEAR true", "SCROLLOVERVIEW-KEY-LEFT true", "SCROLLOVERVIEW-KEY-MODIFIED true",
                       "SCROLLOVERVIEW-SHORTCUTS-BLOCKED true", "SCROLLOVERVIEW-SHORTCUTS-BLOCKED false", "SCROLLOVERVIEW-KEY-DOWN true", "SCROLLOVERVIEW-KEY-UP true", "SCROLLOVERVIEW-KEY-RIGHT true"]:
            if marker not in output:
                raise RuntimeError(f"Runtime operation did not pass: {marker}; inspect {args.log}")
        errors = [line for line in output.splitlines() if
                  ("scrolloverview" in line.lower() and any(token in line for token in
                   ("TypeError", "ReferenceError", "is not a type", "Cannot assign", "Error:", "Unable to assign", "could not update shortcut inhibition")))]
        if errors:
            raise RuntimeError("QML runtime errors:\n" + "\n".join(errors[:20]))
        if args.screenshot and not args.screenshot.exists():
            raise RuntimeError(f"Overview capture was not saved; inspect {args.log}")
        if args.hot_reload and "Scroll Overview hotreload loaded" not in output:
            raise RuntimeError(f"The compositor retained stale QML during reload; inspect {args.log}")
        print(f"Virtual KWin smoke passed: shared bridge, three desktops, four live previews, stacking, splitting, moving between desktops, focus, open and close. Log: {args.log}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
