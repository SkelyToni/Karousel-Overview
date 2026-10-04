#!/usr/bin/env python3
"""Install locally and patch Karousel 0.17, with exact backup/restore checks."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
IMPORT = 'import "../../../../effects/scrolloverview/contents/ui/Bridge.js" as ScrollOverviewBridge'
ATTACH = """        ScrollOverviewBridge.attach(qmlBase.karouselInstance, Workspace,
            Karousel.scrollOverviewCreateColumn);"""
DETACH = "        ScrollOverviewBridge.detach(qmlBase.karouselInstance);"
ADAPTER = """
// BEGIN ScrollOverview adapter
function scrollOverviewCreateColumn(grid, leftColumn) {
    return new Column(grid, leftColumn);
}
// END ScrollOverview adapter
"""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def patch_qml(text):
    if "ScrollOverviewBridge" in text:
        raise ValueError("Karousel is already patched without a matching installation manifest")
    init = "        qmlBase.karouselInstance = Karousel.init();"
    destroy = "        qmlBase.karouselInstance.destroy();"
    if text.count(init) != 1 or text.count(destroy) != 1:
        raise ValueError("Unsupported Karousel main.qml; expected the 0.17 lifecycle hooks")
    text = IMPORT + "\n" + text
    text = text.replace(init, init + "\n" + ATTACH)
    text = text.replace(destroy, DETACH + "\n" + destroy)
    # Three-finger scrolling must not move actual tiled windows behind the overview.
    for call in ["gestureScrollFinish()", "gestureScroll(-progress)", "gestureScroll(progress)"]:
        text = text.replace("qmlBase.karouselInstance." + call,
                            "if (!ScrollOverviewBridge.isVisible()) qmlBase.karouselInstance." + call)
    return text


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".scrolloverview-tmp")
    temporary.write_bytes(data)
    temporary.replace(path)


def command(*args):
    executable = shutil.which(args[0])
    if not executable and args[0] == "qdbus6":
        executable = shutil.which("qdbus")
    if not executable:
        raise RuntimeError(f"Required command is missing: {args[0]}")
    result = subprocess.run([executable, *args[1:]], check=True, capture_output=True, text=True)
    return result.stdout.strip()


def load_effect(plugin_id):
    # KPackage caches discovery only during the first 20 seconds of KWin startup.
    for attempt in range(23):
        if command("qdbus6", "org.kde.KWin", "/Effects", "org.kde.kwin.Effects.loadEffect", plugin_id) == "true":
            return
        if command("qdbus6", "org.kde.KWin", "/Effects", "org.kde.kwin.Effects.isEffectLoaded", plugin_id) == "true":
            return
        if attempt < 22:
            time.sleep(1)
    raise RuntimeError("KWin could not load " + plugin_id + "; inspect its QML logs")


def effect_id():
    content = bytearray()
    for file in sorted((ROOT / "effect").rglob("*")):
        if file.is_file():
            content.extend(str(file.relative_to(ROOT / "effect")).encode())
            content.extend(file.read_bytes())
    return "scrolloverview-" + digest(content)[:12]


def install_effect(data_home, plugin_id, previous_id):
    effects = data_home / "kwin/effects"
    shared = effects / "scrolloverview/contents/ui/Bridge.js"
    atomic_write(shared, (ROOT / "effect/contents/ui/Bridge.js").read_bytes())
    package = effects / plugin_id
    shutil.copytree(ROOT / "effect", package, dirs_exist_ok=True)
    metadata = json.loads((package / "metadata.json").read_text())
    metadata["KPlugin"]["Id"] = plugin_id
    atomic_write(package / "metadata.json", json.dumps(metadata, indent=2).encode())
    main = package / "contents/ui/main.qml"
    text = main.read_text().replace('import "Bridge.js" as Bridge',
                                   'import "../../../scrolloverview/contents/ui/Bridge.js" as Bridge')
    atomic_write(main, text.encode())
    # Keep retired assets for rollback, but show only the current effect in settings.
    for retired in {"scrolloverview", previous_id} - {plugin_id}:
        old_metadata = effects / retired / "metadata.json"
        if old_metadata.exists():
            old_metadata.replace(old_metadata.with_name("metadata.json.retired"))
    return package


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["install", "uninstall", "check"])
    parser.add_argument("--data-home", type=Path, default=Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")))
    parser.add_argument("--karousel", type=Path, help="Writable installed Karousel package directory")
    parser.add_argument("--copy-karousel-from", type=Path, help="Copy a system/Nix Karousel package into the user-local scripts directory first")
    parser.add_argument("--activate", action="store_true", help="Enable Scroll Overview and disable Plasma Overview (install only)")
    parser.add_argument("--reload-effect", action="store_true", help="Reload only the effect after updating it; preserve the running Karousel layout")
    args = parser.parse_args()
    if args.activate and args.action != "install":
        parser.error("--activate applies only to install")
    if args.copy_karousel_from and args.action != "install":
        parser.error("--copy-karousel-from applies only to install")
    if args.reload_effect and (args.action != "install" or args.activate):
        parser.error("--reload-effect applies to install and cannot be combined with --activate")
    data_home = args.data_home.resolve()
    effect = data_home / "kwin/effects/scrolloverview"
    karousel = (args.karousel or data_home / "kwin/scripts/karousel").resolve()
    # The common bridge URL is what gives both QML imports the same library state.
    if karousel != data_home / "kwin/scripts/karousel":
        raise ValueError("Karousel must be at DATA_HOME/kwin/scripts/karousel so bridge imports resolve identically. Copy a system-installed package there first.")
    if args.copy_karousel_from and not karousel.exists():
        source = args.copy_karousel_from.resolve()
        source_metadata = json.loads((source / "metadata.json").read_text())
        if source_metadata["KPlugin"]["Version"] not in ("0.17", "0.17.0"):
            raise ValueError("The source package must be Karousel 0.17")
        shutil.copytree(source, karousel)
        for path in [karousel, *karousel.rglob("*")]:
            path.chmod(0o755 if path.is_dir() else 0o644)
    manifest_path = karousel / ".scrolloverview-backup/manifest.json"
    files = [karousel / "contents/ui/main.qml", karousel / "contents/code/main.js"]
    metadata = json.loads((karousel / "metadata.json").read_text())
    version = metadata["KPlugin"]["Version"]
    if version not in ("0.17", "0.17.0"):
        raise ValueError(f"This integration targets Karousel 0.17; found {version}")
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else None
    previous_id = manifest.get("effect_id", "scrolloverview") if manifest else "scrolloverview"
    plugin_id = effect_id()
    if manifest:
        for file in files:
            entry = manifest["files"][str(file.relative_to(karousel))]
            if digest(file.read_bytes()) != entry["patched"]:
                raise ValueError(f"{file} changed since installation; refusing to overwrite it. Preserve your changes and restore manually from {manifest_path.parent}.")
    if args.action == "check":
        if not manifest:
            raise ValueError("Scroll Overview bridge is not installed")
        if not (effect / "contents/ui/Bridge.js").exists():
            raise ValueError("Installed effect is missing its shared bridge")
        print(f"Karousel {version} bridge and installed effect are present; runtime verification is still required.")
        return
    if args.action == "uninstall":
        if not manifest:
            raise ValueError("No Scroll Overview backup manifest was found")
        originals = []
        for file in files:
            entry = manifest["files"][str(file.relative_to(karousel))]
            original = (manifest_path.parent / entry["backup"]).read_bytes()
            if digest(original) != entry["original"]:
                raise ValueError(f"Backup checksum mismatch for {file}")
            originals.append(original)
        for file, original in zip(files, originals):
            atomic_write(file, original)
        manifest_path.unlink()
        # Keep backup files for review; disable the effect before deleting its files.
        print("Karousel restored. Disable Scroll Overview and re-enable Overview in Desktop Effects, then restart the Karousel script. Effect files and original backups remain available.")
        return
    if not manifest:
        originals = [file.read_bytes() for file in files]
        js = originals[1].decode()
        if "class Column" not in js or "class World" not in js or "function init(" not in js:
            raise ValueError("Karousel main.js does not match the expected 0.17 compiled structure")
        patched = [patch_qml(originals[0].decode()).encode(), (js + ADAPTER).encode()]
        manifest = {"version": version, "files": {}}
        for i, (file, original, updated) in enumerate(zip(files, originals, patched)):
            backup = f"original-{i}-{file.name}"
            entry = {"backup": backup, "original": digest(original), "patched": digest(updated)}
            manifest["files"][str(file.relative_to(karousel))] = entry
            atomic_write(manifest_path.parent / backup, original)
        # Install the common library before loading the patched script.
        effect_package = install_effect(data_home, plugin_id, previous_id)
        for file, updated in zip(files, patched):
            atomic_write(file, updated)
    else:
        effect_package = install_effect(data_home, plugin_id, previous_id)
    manifest["effect_id"] = plugin_id
    atomic_write(manifest_path, json.dumps(manifest, indent=2).encode())
    print(f"Installed {effect_package}; Karousel originals are in {manifest_path.parent}.")
    if args.activate or args.reload_effect:
        if previous_id != plugin_id:
            command("kwriteconfig6", "--file", "kwinrc", "--group", "Plugins", "--key", previous_id + "Enabled", "false")
        command("kwriteconfig6", "--file", "kwinrc", "--group", "Plugins", "--key", plugin_id + "Enabled", "true")
        command("qdbus6", "org.kde.KWin", "/Effects", "org.kde.kwin.Effects.unloadEffect", previous_id)
    if args.activate:
        command("kwriteconfig6", "--file", "kwinrc", "--group", "Plugins", "--key", "overviewEnabled", "false")
        command("qdbus6", "org.kde.KWin", "/KWin", "org.kde.KWin.reconfigure")
        command("qdbus6", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.unloadScript", "karousel")
        command("qdbus6", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.loadDeclarativeScript", str(files[0]), "karousel")
        command("qdbus6", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.start")
        # A running compositor can retain its cached package list during reconfigure.
        command("qdbus6", "org.kde.KWin", "/Effects", "org.kde.kwin.Effects.unloadEffect", "overview")
        load_effect(plugin_id)
        print("Scroll Overview enabled and Karousel restarted. Use Meta+Ctrl+O or swipe up with four fingers.")
    elif args.reload_effect:
        load_effect(plugin_id)
        print("Scroll Overview updated and reloaded; the running Karousel layout was preserved.")
    else:
        print("Restart Karousel in System Settings → Window Management → KWin Scripts. In Desktop Effects, disable Overview and enable Scroll Overview. Use Meta+Ctrl+O or swipe up with four fingers.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
