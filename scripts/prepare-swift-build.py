#!/usr/bin/env python3
"""Prepare persistent outputs for Swift's own cross-file incremental compiler.

Make still invokes swiftc with every source; the Swift driver decides which files
need recompilation. Configuration changes invalidate this architecture's cache.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess


def write_if_changed(path, value):
    content = json.dumps(value, indent=2, sort_keys=True) + "\n"
    if path.exists() and path.read_text() == content:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(content)
    temporary.replace(path)
    return True


def prepare(cache, source_root, settings):
    sources = sorted(source_root.rglob("*.swift"))
    if not sources:
        raise ValueError(f"No Swift sources under {source_root}")
    config_path = cache / "config.json"
    try:
        previous = json.loads(config_path.read_text())
    except (FileNotFoundError, ValueError):
        previous = None
    # Swift dependency records are compiler-specific. Never reuse objects across
    # compiler, SDK, deployment-target or flag changes.
    if cache.exists() and (not isinstance(previous, dict) or previous.get("settings") != settings):
        shutil.rmtree(cache)
    cache.mkdir(parents=True, exist_ok=True)
    output_map = {"": {"swift-dependencies": str(cache / "master.swiftdeps")}}
    missing_output = False
    for source in sources:
        base = cache / source.relative_to(source_root)
        base.parent.mkdir(parents=True, exist_ok=True)
        outputs = {"object": str(base.with_suffix(".o")),
                   "swift-dependencies": str(base.with_suffix(".swiftdeps"))}
        output_map[str(source)] = outputs
        missing_output |= any(not Path(path).exists() for path in outputs.values())
    map_changed = write_if_changed(cache / "output-file-map.json", output_map)
    config_changed = write_if_changed(config_path, {"settings": settings, "sources": [str(s) for s in sources]})
    # A deleted intermediate must trigger swiftc even if sources are unchanged.
    if not config_changed and (map_changed or missing_output):
        config_path.touch()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, default=Path("Sources/NetMenu"))
    parser.add_argument("--compiler", default="swiftc")
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--jobs", type=int, required=True)
    parser.add_argument("flags", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    compiler = Path(shutil.which(args.compiler) or args.compiler).resolve(strict=True)
    sdk = args.sdk.resolve(strict=True)
    sdk_settings = sdk / "SDKSettings.json"
    settings = {
        "compiler": str(compiler),
        "compiler_mtime_ns": compiler.stat().st_mtime_ns,
        "compiler_version": subprocess.check_output([args.compiler, "--version"], text=True, stderr=subprocess.STDOUT).strip(),
        "sdk": str(sdk),
        "sdk_mtime_ns": sdk.stat().st_mtime_ns,
        "sdk_settings_mtime_ns": sdk_settings.stat().st_mtime_ns if sdk_settings.exists() else None,
        "target": args.target,
        "jobs": args.jobs,
        "flags": args.flags[1:] if args.flags[:1] == ["--"] else args.flags,
    }
    prepare(args.cache, args.source_root, settings)


if __name__ == "__main__":
    main()
