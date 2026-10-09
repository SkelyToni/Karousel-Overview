import importlib.util
import json
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("installer", ROOT / "tools/install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

QML = '''import QtQuick 6.0
import org.kde.kwin 3.0
Item {
    Component.onCompleted: {
        qmlBase.karouselInstance = Karousel.init();
    }
    Component.onDestruction: {
        qmlBase.karouselInstance.destroy();
    }
    SwipeGestureHandler {
        onActivated: qmlBase.karouselInstance.gestureScrollFinish()
        onProgressChanged: qmlBase.karouselInstance.gestureScroll(-progress)
    }
}
'''
JS = "class Column {}\nclass World {}\nfunction init() {}\n"


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.data = Path(self.temp.name)
        self.package = self.data / "kwin/scripts/karousel"
        (self.package / "contents/ui").mkdir(parents=True)
        (self.package / "contents/code").mkdir()
        self.qml = self.package / "contents/ui/main.qml"
        self.js = self.package / "contents/code/main.js"
        self.qml.write_text(QML)
        self.js.write_text(JS)
        (self.package / "metadata.json").write_text(json.dumps({"KPlugin": {"Version": "0.17"}}))

    def tearDown(self):
        self.temp.cleanup()

    def run_installer(self, action):
        return subprocess.run([sys.executable, str(ROOT / "tools/install.py"), action,
                               "--data-home", str(self.data)], capture_output=True, text=True)

    def test_round_trip_and_idempotent_update(self):
        first = self.run_installer("install")
        self.assertEqual(first.returncode, 0, first.stderr)
        patched = self.qml.read_bytes()
        self.assertIn(b"ScrollOverviewBridge.attach", patched)
        self.assertIn(b"if (!ScrollOverviewBridge.isVisible())", patched)
        self.assertIn("scrollOverviewCreateColumn", self.js.read_text())
        # Both imports normalize to exactly the same Bridge.js URL.
        bridge = (self.qml.parent / "../../../../effects/scrolloverview/contents/ui/Bridge.js").resolve()
        self.assertEqual(bridge, self.data / "kwin/effects/scrolloverview/contents/ui/Bridge.js")
        self.assertTrue(bridge.exists())
        self.assertEqual(self.run_installer("install").returncode, 0)
        self.assertEqual(self.qml.read_bytes(), patched)
        self.assertEqual(self.run_installer("check").returncode, 0)
        restored = self.run_installer("uninstall")
        self.assertEqual(restored.returncode, 0, restored.stderr)
        self.assertEqual(self.qml.read_text(), QML)
        self.assertEqual(self.js.read_text(), JS)

    def test_modified_install_is_preserved(self):
        self.assertEqual(self.run_installer("install").returncode, 0)
        self.qml.write_text(self.qml.read_text() + "// independent user change\n")
        changed = self.qml.read_bytes()
        for action in ("install", "uninstall", "check"):
            result = self.run_installer(action)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("changed since installation", result.stderr)
            self.assertEqual(self.qml.read_bytes(), changed)

    def test_rejects_unknown_version_before_changes(self):
        (self.package / "metadata.json").write_text(json.dumps({"KPlugin": {"Version": "0.18"}}))
        result = self.run_installer("install")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.qml.read_text(), QML)
        self.assertFalse((self.data / "kwin/effects/scrolloverview").exists())

    def test_unknown_lifecycle_is_rejected(self):
        with self.assertRaises(ValueError):
            installer.patch_qml("Item {}")

    def test_update_reloads_effect_without_restarting_karousel(self):
        self.assertEqual(self.run_installer("install").returncode, 0)
        original = self.qml.read_bytes()
        with mock.patch.object(sys, "argv", ["install.py", "install", "--data-home", str(self.data), "--reload-effect"]):
            with mock.patch.object(installer, "command", return_value="true") as command:
                installer.main()
        self.assertEqual(self.qml.read_bytes(), original)
        self.assertEqual(command.call_args_list[-2:], [
            mock.call("qdbus6", "org.kde.KWin", "/Effects", "org.kde.kwin.Effects.unloadEffect", installer.effect_id()),
            mock.call("qdbus6", "org.kde.KWin", "/Effects", "org.kde.kwin.Effects.loadEffect", installer.effect_id())])
        self.assertFalse(any("/Scripting" in call.args for call in command.call_args_list))

    def test_reload_unloads_revisions_missing_from_manifest(self):
        self.assertEqual(self.run_installer("install").returncode, 0)
        loaded = "kwin4_effect_geometry_change\nscrolloverview-0123456789ab\n" + installer.effect_id()
        with mock.patch.object(sys, "argv", ["install.py", "install", "--data-home", str(self.data), "--reload-effect"]):
            with mock.patch.object(installer, "command",
                                   side_effect=lambda *args: loaded if args[-1].endswith("loadedEffects") else "true") as command:
                installer.main()
        unloaded = [call.args[-1] for call in command.call_args_list if "org.kde.kwin.Effects.unloadEffect" in call.args]
        self.assertIn("scrolloverview-0123456789ab", unloaded)
        self.assertNotIn("kwin4_effect_geometry_change", unloaded)
        self.assertIn(mock.call("kwriteconfig6", "--file", "kwinrc", "--group", "Plugins",
                                "--key", "scrolloverview-0123456789abEnabled", "false"), command.call_args_list)

    def test_changed_qml_uses_fresh_package_and_same_shared_bridge(self):
        self.assertEqual(self.run_installer("install").returncode, 0)
        manifest_path = self.package / ".scrolloverview-backup/manifest.json"
        previous_id = json.loads(manifest_path.read_text())["effect_id"]
        source = self.data / "source"
        shutil.copytree(ROOT / "effect", source / "effect")
        main = source / "effect/contents/ui/main.qml"
        main.write_text(main.read_text() + "\n// another revision\n")
        with mock.patch.object(installer, "ROOT", source):
            with mock.patch.object(sys, "argv", ["install.py", "install", "--data-home", str(self.data)]):
                installer.main()
        current_id = json.loads(manifest_path.read_text())["effect_id"]
        self.assertNotEqual(current_id, previous_id)
        effects = self.data / "kwin/effects"
        self.assertFalse((effects / previous_id / "metadata.json").exists())
        self.assertTrue((effects / previous_id / "metadata.json.retired").exists())
        main = effects / current_id / "contents/ui/main.qml"
        self.assertIn('../../../scrolloverview/contents/ui/Bridge.js', main.read_text())
        self.assertEqual((main.parent / '../../../scrolloverview/contents/ui/Bridge.js').resolve(),
                         effects / 'scrolloverview/contents/ui/Bridge.js')

    def test_copy_from_readonly_system_package(self):
        target_data = self.data / "local"
        for path in [self.package, *self.package.rglob("*")]:
            path.chmod(0o555 if path.is_dir() else 0o444)
        try:
            result = subprocess.run([sys.executable, str(ROOT / "tools/install.py"), "install",
                                     "--data-home", str(target_data), "--copy-karousel-from", str(self.package)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.qml.read_text(), QML)
            local_qml = target_data / "kwin/scripts/karousel/contents/ui/main.qml"
            self.assertIn("ScrollOverviewBridge.attach", local_qml.read_text())
            self.assertTrue(local_qml.stat().st_mode & 0o200)
        finally:
            for path in [self.package, *self.package.rglob("*")]:
                path.chmod(0o755 if path.is_dir() else 0o644)


if __name__ == "__main__":
    unittest.main()
