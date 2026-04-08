#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import shlex
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib  # type: ignore[no-redef]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Read logical environment metadata from a Pixi manifest."
    )
    parser.add_argument(
        "--manifest",
        required=True,
        help="Path to the Pixi manifest to inspect.",
    )
    parser.add_argument(
        "--format",
        choices=("json", "shell"),
        default="json",
        help="Output format.",
    )
    return parser.parse_args()


def load_metadata(manifest_path: Path) -> dict[str, object]:
    with manifest_path.open("rb") as fh:
        manifest = tomllib.load(fh)

    raw_environments = manifest.get("environments", {})
    if not isinstance(raw_environments, dict):
        raise ValueError("Manifest environments table is missing or malformed.")

    all_environments = sorted(
        name
        for name in raw_environments
        if isinstance(name, str) and name != "default"
    )
    runtime_environments = sorted(
        name for name in all_environments if not name.endswith("-test")
    )
    test_environments = sorted(
        name for name in all_environments if name.endswith("-test")
    )
    missing_test_pairs = sorted(
        name
        for name in runtime_environments
        if f"{name}-test" not in raw_environments
    )

    return {
        "manifest_path": str(manifest_path),
        "all_environments": all_environments,
        "runtime_environments": runtime_environments,
        "test_environments": test_environments,
        "missing_test_pairs": missing_test_pairs,
    }


def emit_shell(metadata: dict[str, object]) -> str:
    lines = []
    for key in (
        "manifest_path",
        "all_environments",
        "runtime_environments",
        "test_environments",
        "missing_test_pairs",
    ):
        value = metadata[key]
        if isinstance(value, list):
            rendered = " ".join(value)
        else:
            rendered = str(value)
        shell_key = f"PIXI_{key.upper()}"
        lines.append(f"{shell_key}={shlex.quote(rendered)}")
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    manifest_path = Path(args.manifest)
    if not manifest_path.is_file():
        print(
            f"Pixi manifest not found at {manifest_path}",
            file=sys.stderr,
        )
        return 1

    try:
        metadata = load_metadata(manifest_path)
    except Exception as exc:  # pragma: no cover - guarded by tests and caller handling
        print(f"Failed to parse Pixi manifest: {exc}", file=sys.stderr)
        return 1

    if args.format == "shell":
        print(emit_shell(metadata))
    else:
        print(json.dumps(metadata, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
