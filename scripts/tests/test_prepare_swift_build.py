import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("prepare_swift_build", Path(__file__).parents[1] / "prepare-swift-build.py")
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class IncrementalBuildTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="netmenu-build-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.sources = self.root / "Sources"
        self.sources.mkdir()
        (self.sources / "main.swift").write_text("print(1)\n")
        self.cache = self.root / "objects"
        self.settings = {"compiler": "swiftc", "sdk": "sdk1", "target": "arm64", "flags": ["-O"]}
        self.prepare()
        self.complete_outputs()

    def prepare(self):
        build.prepare(self.cache, self.sources, self.settings)

    def output_map(self):
        return json.loads((self.cache / "output-file-map.json").read_text())

    def complete_outputs(self):
        for source, outputs in self.output_map().items():
            if source:
                for output in outputs.values():
                    Path(output).write_text("cached")
        # Old timestamps make invalidation assertions independent of clock resolution.
        os.utime(self.cache / "config.json", ns=(1_000_000_000, 1_000_000_000))

    def test_noop_keeps_stamps_and_source_body_edits_preserve_cached_objects(self):
        before = (self.cache / "config.json").stat().st_mtime_ns
        self.prepare()
        self.assertEqual((self.cache / "config.json").stat().st_mtime_ns, before)
        (self.sources / "main.swift").write_text("print(2)\n")
        self.prepare()
        self.assertEqual((self.cache / "config.json").stat().st_mtime_ns, before)
        self.assertEqual((self.cache / "main.o").read_text(), "cached")

    def test_adding_and_removing_sources_updates_the_input_set(self):
        extra = self.sources / "Extra.swift"
        extra.write_text("let extra = 1\n")
        self.prepare()
        self.assertIn(str(extra), self.output_map())
        self.complete_outputs()
        extra.unlink()
        self.prepare()
        self.assertNotIn(str(extra), self.output_map())
        self.assertGreater((self.cache / "config.json").stat().st_mtime_ns, 1_000_000_000)

    def test_nested_sources_with_same_name_have_distinct_outputs(self):
        (self.sources / "Other").mkdir()
        second = self.sources / "Other" / "main.swift"
        second.write_text("let other = 1\n")
        self.prepare()
        mapped = self.output_map()
        self.assertNotEqual(mapped[str(second)]["object"], mapped[str(self.sources / "main.swift")]["object"])

    def test_deleted_object_or_dependency_file_forces_a_driver_run(self):
        for suffix in [".o", ".swiftdeps"]:
            with self.subTest(suffix=suffix):
                self.complete_outputs()
                (self.cache / ("main" + suffix)).unlink()
                self.prepare()
                self.assertGreater((self.cache / "config.json").stat().st_mtime_ns, 1_000_000_000)

    def test_compiler_sdk_target_and_flags_changes_invalidate_objects(self):
        for field, value in [("compiler", "swiftc2"), ("sdk", "sdk2"), ("target", "x86_64"), ("flags", ["-Onone"])]:
            with self.subTest(field=field):
                self.complete_outputs()
                self.settings[field] = value
                self.prepare()
                self.assertFalse((self.cache / "main.o").exists())

    def test_missing_or_invalid_config_cannot_reuse_unknown_objects(self):
        for content in [None, "bad json", "{}", "[]"]:
            with self.subTest(content=content):
                self.complete_outputs()
                config = self.cache / "config.json"
                if content is None:
                    config.unlink()
                else:
                    config.write_text(content)
                self.prepare()
                self.assertFalse((self.cache / "main.o").exists())

    def test_missing_map_is_repaired_and_invalidates_binary(self):
        (self.cache / "output-file-map.json").unlink()
        self.prepare()
        self.assertTrue((self.cache / "output-file-map.json").exists())
        self.assertGreater((self.cache / "config.json").stat().st_mtime_ns, 1_000_000_000)


if __name__ == "__main__":
    unittest.main()
