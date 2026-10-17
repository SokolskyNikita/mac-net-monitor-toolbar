"""Exercise cache invalidation and app packaging with a tiny real Swift program."""
import json
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import unittest


class MakeBuildIntegrationTests(unittest.TestCase):
    def test_incremental_builds_and_configuration_changes_produce_current_binaries(self):
        repo = Path(__file__).resolve().parents[2]
        arch = platform.machine()
        with tempfile.TemporaryDirectory(prefix="netmenu-make-test-") as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            (root / "Resources").mkdir()
            source = root / "Sources/NetMenu"
            source.mkdir(parents=True)
            shutil.copy2(repo / "Makefile", root / "Makefile")
            for script in ["prepare-swift-build.py", "run-if-stale.py", "generate-icon.swift"]:
                shutil.copy2(repo / "scripts" / script, root / "scripts" / script)
            for filename in ["Info.plist", "AppIcon.icns"]:
                shutil.copy2(repo / "Resources" / filename, root / "Resources" / filename)
            (source / "main.swift").write_text("print(message())\n")
            value = source / "value.swift"
            value.write_text('func message() -> String { "initial" }\n')
            binary = root / "build/NetMenu"
            signature = root / "NetMenu.app/Contents/_CodeSignature/CodeResources"
            object_file = root / f"build/objects/{arch}/value.o"

            def make(*options, succeeds=True):
                result = subprocess.run(["make", "app", f"ARCHS={arch}", *options], cwd=root,
                                        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                if succeeds:
                    self.assertEqual(result.returncode, 0, result.stdout)
                else:
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                return result.stdout

            def output():
                return subprocess.check_output([str(binary)], text=True).strip()

            make()
            self.assertEqual(output(), "initial")
            timestamps = [p.stat().st_mtime_ns for p in [binary, signature, object_file]]
            make()
            self.assertEqual(timestamps, [p.stat().st_mtime_ns for p in [binary, signature, object_file]])

            value.write_text('func message() -> String { "edited" }\n')
            make()
            self.assertEqual(output(), "edited")
            object_file.unlink()
            missing_output_log = make()
            self.assertTrue(object_file.exists(), missing_output_log)
            self.assertEqual(output(), "edited")

            # Rename changes the source set without editing the remaining files.
            renamed = source / "renamed.swift"
            value.rename(renamed)
            make()
            self.assertEqual(output(), "edited")
            mapping = json.loads((root / f"build/objects/{arch}/output-file-map.json").read_text())
            self.assertIn("Sources/NetMenu/renamed.swift", mapping)
            self.assertNotIn("Sources/NetMenu/value.swift", mapping)

            make("SWIFT_FLAGS=-Onone", "MIN_OS=15.0")
            config = json.loads((root / f"build/objects/{arch}/config.json").read_text())["settings"]
            self.assertEqual(config["flags"], ["-Onone"])
            self.assertEqual(config["target"], f"{arch}-apple-macos15.0")
            metadata = subprocess.check_output(["xcrun", "vtool", "-show-build", str(binary)], text=True)
            self.assertIn("minos 15.0", metadata)
            self.assertEqual(output(), "edited")

            make("ARCHS=arm64 x86_64")
            self.assertEqual(set(subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()),
                             {"arm64", "x86_64"})
            make()
            self.assertEqual(subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip(), arch)

            # Resource-only edits re-sign the bundle without recompiling Swift.
            compiled_at = binary.stat().st_mtime_ns
            plist = root / "Resources/Info.plist"
            info = plistlib.loads(plist.read_bytes())
            info["CFBundleVersion"] = "999"
            plist.write_bytes(plistlib.dumps(info))
            make()
            self.assertEqual(binary.stat().st_mtime_ns, compiled_at)
            subprocess.run(["codesign", "--verify", "--strict", str(root / "NetMenu.app")], check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            renamed.write_text("not valid Swift !!!\n")
            make(succeeds=False)
            renamed.write_text('func message() -> String { "recovered" }\n')
            make()
            self.assertEqual(output(), "recovered")


if __name__ == "__main__":
    unittest.main()
