#!/usr/bin/env python3

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import click


SUMMARY_FIELDS = (
    "name",
    "timestamp",
    "amiId",
    "dockerImage",
    "packageVersions",
    "imageJsonUrl",
)


def require_dict(value: object, label: str) -> dict[str, Any]:
    """Require a value to be a dictionary.

    Parameters
    ----------
    value
        Value to validate.
    label
        Human-readable label used in error messages.

    Returns
    -------
    dict[str, Any]
        The validated dictionary.

    Raises
    ------
    click.ClickException
        If the value is not a dictionary.
    """
    if not isinstance(value, dict):
        raise click.ClickException(f"{label} is missing or malformed.")
    return value


def require_list(value: object, label: str) -> list[Any]:
    """Require a value to be a list.

    Parameters
    ----------
    value
        Value to validate.
    label
        Human-readable label used in error messages.

    Returns
    -------
    list[Any]
        The validated list.

    Raises
    ------
    click.ClickException
        If the value is not a list.
    """
    if not isinstance(value, list):
        raise click.ClickException(f"{label} must be a JSON array.")
    return value


def load_json(path: Path, label: str) -> Any:
    """Load a JSON file.

    Parameters
    ----------
    path
        JSON file path.
    label
        Human-readable label used in error messages.

    Returns
    -------
    Any
        Parsed JSON payload.

    Raises
    ------
    click.ClickException
        If the file is not valid JSON.
    """
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise click.ClickException(f"{label} is not valid JSON: {exc}") from exc


def extract_summary(image_record: dict[str, Any]) -> dict[str, Any]:
    """Extract global-manifest summary fields from an image record.

    Parameters
    ----------
    image_record
        Parsed image JSON payload.

    Returns
    -------
    dict[str, Any]
        Summary payload suitable for the global manifest.

    Raises
    ------
    click.ClickException
        If a required summary field is missing.
    """
    summary: dict[str, Any] = {}
    missing_fields: list[str] = []
    for field in SUMMARY_FIELDS:
        try:
            summary[field] = image_record[field]
        except KeyError:
            missing_fields.append(field)

    if missing_fields:
        raise click.ClickException(
            f"Image JSON is missing required summary field(s): {', '.join(missing_fields)}"
        )

    return summary


def update_manifest(manifest_path: Path, image_json_path: Path) -> None:
    """Append an image summary to a global manifest file.

    Parameters
    ----------
    manifest_path
        Path to the global manifest JSON file.
    image_json_path
        Path to the generated image JSON file.

    Raises
    ------
    click.ClickException
        If the manifest is malformed or already contains the image name.
    """
    manifest = require_list(load_json(manifest_path, "Global manifest"), "Global manifest")
    image_record = require_dict(load_json(image_json_path, "Image JSON"), "Image JSON")
    summary = extract_summary(image_record)

    image_name = summary["name"]
    for entry in manifest:
        if isinstance(entry, dict) and entry.get("name") == image_name:
            raise click.ClickException(f"Manifest already contains image '{image_name}'.")

    manifest_path.write_text(
        json.dumps([*manifest, summary], indent=2) + "\n",
        encoding="utf-8",
    )


@click.command()
@click.option(
    "--manifest",
    "manifest_path",
    required=True,
    type=click.Path(exists=True, dir_okay=False, path_type=Path),
    help="Path to an existing global manifest JSON file.",
)
@click.option(
    "--image-json",
    "image_json_path",
    required=True,
    type=click.Path(exists=True, dir_okay=False, path_type=Path),
    help="Path to a generated image JSON file.",
)
def cli(manifest_path: Path, image_json_path: Path) -> None:
    """Append an image summary to a global manifest JSON file."""
    update_manifest(manifest_path, image_json_path)
    click.echo(manifest_path)


if __name__ == "__main__":
    cli()
