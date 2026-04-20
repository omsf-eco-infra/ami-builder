#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import shlex
import sys
from pathlib import Path
from typing import Any

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


def _require_table(value: object, label: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} table is missing or malformed.")
    return value


def _require_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label} must be a non-empty string.")
    return value.strip()


def _require_string_list(value: object, label: str) -> list[str]:
    if not isinstance(value, list) or not value:
        raise ValueError(f"{label} must be a non-empty list of strings.")

    strings = []
    seen = set()
    duplicates = []
    for item in value:
        if not isinstance(item, str) or not item.strip():
            raise ValueError(f"{label} must contain only non-empty strings.")
        name = item.strip()
        if name in seen:
            duplicates.append(name)
        seen.add(name)
        strings.append(name)

    if duplicates:
        raise ValueError(f"{label} contains duplicate entries: {', '.join(duplicates)}")

    return strings


def _build_environment_matrix(
    selected_environments: list[str],
    environment_root: Path,
) -> list[dict[str, str]]:
    matrix = []
    for env_name in selected_environments:
        env_dir = environment_root / env_name
        smoke_script = env_dir / "smoke-tests.sh"
        full_script = env_dir / "full-tests.sh"
        if not smoke_script.is_file():
            raise ValueError(
                f"Selected environment '{env_name}' is missing smoke-tests.sh at {smoke_script}."
            )
        if not full_script.is_file():
            raise ValueError(
                f"Selected environment '{env_name}' is missing full-tests.sh at {full_script}."
            )
        matrix.append(
            {
                "name": env_name,
                "smoke_script": str(smoke_script),
                "full_script": str(full_script),
            }
        )
    return matrix


def load_metadata(manifest_path: Path) -> dict[str, object]:
    with manifest_path.open("rb") as fh:
        manifest = tomllib.load(fh)

    raw_environments = _require_table(
        manifest.get("environments", {}),
        "Manifest environments",
    )

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

    tool_table = _require_table(manifest.get("tool"), "Manifest tool")
    image_builder = _require_table(
        tool_table.get("image-builder"),
        "Manifest tool.image-builder",
    )
    image_name = _require_string(image_builder.get("image_name"), "image_name")
    default_environment = _require_string(
        image_builder.get("default_environment"),
        "default_environment",
    )
    selected_environments = _require_string_list(
        image_builder.get("environments"),
        "environments",
    )

    for env_name in selected_environments:
        if env_name.endswith("-test"):
            raise ValueError(
                f"Selected environment '{env_name}' must be a runtime environment, not a test environment."
            )
        if env_name not in raw_environments:
            raise ValueError(
                f"Selected environment '{env_name}' is missing from the Pixi workspace manifest."
            )
        if f"{env_name}-test" not in raw_environments:
            raise ValueError(
                f"Selected environment '{env_name}' is missing paired test environment '{env_name}-test'."
            )

    if default_environment not in selected_environments:
        raise ValueError(
            f"default_environment '{default_environment}' must be included in environments."
        )

    environment_matrix = _build_environment_matrix(
        selected_environments,
        manifest_path.parent,
    )

    return {
        "manifest_path": str(manifest_path),
        "all_environments": all_environments,
        "runtime_environments": runtime_environments,
        "test_environments": test_environments,
        "missing_test_pairs": missing_test_pairs,
        "image_name": image_name,
        "default_environment": default_environment,
        "selected_environments": selected_environments,
        "environment_matrix": environment_matrix,
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

    image_builder_fields: tuple[tuple[str, Any], ...] = (
        ("IMAGE_BUILDER_IMAGE_NAME", metadata["image_name"]),
        ("IMAGE_BUILDER_DEFAULT_ENVIRONMENT", metadata["default_environment"]),
        ("IMAGE_BUILDER_ENVIRONMENTS", metadata["selected_environments"]),
        ("IMAGE_BUILDER_ENVIRONMENT_MATRIX", metadata["environment_matrix"]),
    )
    for shell_key, value in image_builder_fields:
        if isinstance(value, (list, dict)):
            rendered = json.dumps(value, separators=(",", ":"))
        else:
            rendered = str(value)
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
