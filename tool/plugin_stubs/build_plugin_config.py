#!/usr/bin/env python3
"""Build an analyzer package_config that resolves Flutter/plugin imports to the stubs.

    python3 tool/plugin_stubs/build_plugin_config.py [--config PATH] [--out PATH]

Takes the harness's `package_config.json` (which resolves `khata_pro` and the plain
Dart dependencies), replaces the Flutter-side entries with these stub packages, and
writes `/tmp/harness/plugin_stubs_config.json`. Then:

    cd /tmp/harness
    ./dartx analyze --packages=plugin_stubs_config.json /home/user/khata_pro/lib

Why a copy rather than editing the harness config: the harness *runs* code, and the
stubs must never be loadable by a test that actually executes something. Analysis only.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

STUB_PACKAGES = [
    "flutter",
    "flutter_riverpod",
    "go_router",
    "flutter_webrtc",
    "nsd",
    "icloud_storage",
    "path_provider",
]
DEFAULT_CONFIG = "/tmp/harness/.dart_tool/package_config.json"
DEFAULT_OUT = "/tmp/harness/plugin_stubs_config.json"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=DEFAULT_CONFIG, help="source package_config.json")
    parser.add_argument("--out", default=DEFAULT_OUT, help="where to write the stub config")
    parser.add_argument("--project", default=str(pathlib.Path(__file__).resolve().parent.parent.parent))
    args = parser.parse_args()

    source = pathlib.Path(args.config)
    if not source.exists():
        print(f"no package config at {source} — run tool/bootstrap_harness.sh first", file=sys.stderr)
        return 2

    data = json.loads(source.read_text())
    project = pathlib.Path(args.project)
    stubs_root = pathlib.Path(__file__).resolve().parent

    # Drop any previous mapping for these names (and for khata_pro, which is re-added
    # below) so the file is idempotent.
    packages = [
        package
        for package in data["packages"]
        if package["name"] not in set(STUB_PACKAGES) | {"khata_pro"}
    ]

    missing: list[str] = []
    for name in STUB_PACKAGES:
        root = stubs_root / name
        if not (root / "pubspec.yaml").exists():
            missing.append(name)
            continue
        packages.append(
            {
                "name": name,
                "rootUri": f"file://{root}",
                "packageUri": "lib/",
                "languageVersion": "3.10",
            }
        )

    packages.append(
        {
            "name": "khata_pro",
            "rootUri": f"file://{project}",
            "packageUri": "lib/",
            "languageVersion": "3.10",
        }
    )

    data["packages"] = packages
    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, indent=2))

    if missing:
        print(f"WARNING: no stub for {', '.join(missing)}", file=sys.stderr)
    print(f"{out}: {len(packages)} packages, {len(STUB_PACKAGES) - len(missing)} stubbed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
