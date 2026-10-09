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
        # Instrument only the staged test copy: add the harness from tests/smoke
        # with one line after each of the two ids it needs.
        ui = temp / "data/kwin/effects" / plugin_id / "contents/ui"
        for harness in (ROOT / "tests/smoke").glob("*.qml"):
            shutil.copy(harness, ui / harness.name)
        delay = 2000 if args.screenshot else 0
        main_qml = ui / "main.qml"
        source = main_qml.read_text()
        hooks = {
            "    id: effect\n": f"    SmokeEffect {{ overview: effect; shortcuts: shortcutGuard; extraDelay: {delay} }}\n",
            "        id: view\n": f"        SmokeView {{ screenView: view; overview: effect; rowItems: rowRepeater; token: dragToken; extraDelay: {delay} }}\n",
        }
        for anchor, hook in hooks.items():
            if source.count(anchor) != 1:
                raise RuntimeError(f"Smoke hook anchor not found exactly once in main.qml: {anchor.strip()}")
            source = source.replace(anchor, anchor + hook)
        main_qml.write_text(source)
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
                    updated_main.write_text(updated_main.read_text() + "\n// hot reload revision\n")
                    subprocess.run([sys.executable, str(source_root / "tools/install.py"), "install",
                                    "--data-home", str(temp / "data"), "--reload-effect"], env=env,
                                   stdout=log, stderr=log, check=True, timeout=10)
                    reloaded_id = json.loads((package / ".scrolloverview-backup/manifest.json").read_text())["effect_id"]
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
        if args.hot_reload and f"Scroll Overview loaded from file://{temp}/data/kwin/effects/{reloaded_id}/" not in output:
            raise RuntimeError(f"The compositor retained stale QML during reload; inspect {args.log}")
        print(f"Virtual KWin smoke passed: shared bridge, three desktops, four live previews, stacking, splitting, moving between desktops, focus, open and close. Log: {args.log}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
