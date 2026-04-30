#!/usr/bin/env python3

from __future__ import annotations

import json
import re
import tomllib
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse

import click
import yaml


class NonEmptyString(click.ParamType):
    """Click parameter type for required non-empty strings."""

    name = "text"

    def convert(
        self,
        value: object,
        param: click.Parameter | None,
        ctx: click.Context | None,
    ) -> str:
        """Convert a command-line value into a stripped non-empty string.

        Parameters
        ----------
        value
            Raw command-line value supplied by Click.
        param
            Click parameter being converted.
        ctx
            Active Click context.

        Returns
        -------
        str
            The stripped input string.

        Raises
        ------
        click.BadParameter
            If the value is not a non-empty string after stripping whitespace.
        """
        if not isinstance(value, str):
            self.fail("must be a string", param, ctx)
        if not value.strip():
            self.fail("must be a non-empty string", param, ctx)
        return value.strip()

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


def require_string(value: object, label: str) -> str:
    """Require a value to be a non-empty string.

    Parameters
    ----------
    value
        Value to validate.
    label
        Human-readable label used in error messages.

    Returns
    -------
    str
        The stripped string value.

    Raises
    ------
    click.ClickException
        If the value is not a non-empty string.
    """
    if not isinstance(value, str) or not value.strip():
        raise click.ClickException(f"{label} must be a non-empty string.")
    return value.strip()


def require_string_list(value: object, label: str) -> list[str]:
    """Require a value to be a non-empty list of unique strings.

    Parameters
    ----------
    value
        Value to validate.
    label
        Human-readable label used in error messages.

    Returns
    -------
    list[str]
        Validated string list with each item stripped.

    Raises
    ------
    click.ClickException
        If the value is not a non-empty list of unique non-empty strings.
    """
    if not isinstance(value, list) or not value:
        raise click.ClickException(f"{label} must be a non-empty list of strings.")

    strings: list[str] = []
    seen: set[str] = set()
    duplicates: list[str] = []
    for item in value:
        name = require_string(item, label)
        if name in seen:
            duplicates.append(name)
        seen.add(name)
        strings.append(name)

    if duplicates:
        raise click.ClickException(
            f"{label} contains duplicate entries: {', '.join(duplicates)}"
        )

    return strings


def load_yaml(path: Path, label: str) -> Any:
    """Load a YAML file.

    Parameters
    ----------
    path
        YAML file path.
    label
        Human-readable label used in error messages.

    Returns
    -------
    Any
        Parsed YAML payload.

    Raises
    ------
    click.ClickException
        If the file is not valid YAML.
    """
    try:
        with path.open(encoding="utf-8") as fh:
            return yaml.safe_load(fh)
    except yaml.YAMLError as exc:
        raise click.ClickException(f"{label} is not valid YAML: {exc}") from exc


def load_toml(path: Path, label: str) -> dict[str, Any]:
    """Load a TOML file.

    Parameters
    ----------
    path
        TOML file path.
    label
        Human-readable label used in error messages.

    Returns
    -------
    dict[str, Any]
        Parsed TOML payload.

    Raises
    ------
    click.ClickException
        If the file is not valid TOML.
    """
    try:
        with path.open("rb") as fh:
            return tomllib.load(fh)
    except tomllib.TOMLDecodeError as exc:
        raise click.ClickException(f"{label} is not valid TOML: {exc}") from exc


def load_selected_environments(manifest_path: Path) -> list[str]:
    """Load selected runtime environments from a Pixi manifest TOML file.

    Parameters
    ----------
    manifest_path
        Path to a ``pixi.toml``-formatted manifest containing
        ``[tool.image-builder]`` metadata.

    Returns
    -------
    list[str]
        Selected runtime environment names.

    Raises
    ------
    click.ClickException
        If selected environments are malformed, missing, or lack paired test
        environments.
    """
    manifest = load_toml(manifest_path, "Pixi manifest")
    manifest_environments = require_dict(
        manifest.get("environments"),
        "Manifest environments",
    )
    tool_table = require_dict(manifest.get("tool"), "Manifest tool")
    image_builder = require_dict(
        tool_table.get("image-builder"),
        "Manifest tool.image-builder",
    )
    selected = require_string_list(
        image_builder.get("environments"),
        "tool.image-builder.environments",
    )

    for env_name in selected:
        if env_name.endswith("-test"):
            raise click.ClickException(
                f"Selected environment '{env_name}' must be a runtime environment."
            )
        if env_name not in manifest_environments:
            raise click.ClickException(
                f"Selected environment '{env_name}' is missing from the Pixi manifest."
            )
        test_env_name = f"{env_name}-test"
        if test_env_name not in manifest_environments:
            raise click.ClickException(
                f"Selected environment '{env_name}' is missing paired test environment '{test_env_name}'."
            )

    return selected


def parse_summary_packages(raw_mappings: tuple[str, ...]) -> dict[str, str]:
    """Parse package summary mappings from CLI option values.

    Parameters
    ----------
    raw_mappings
        Raw ``DISPLAY=PACKAGE`` values supplied through ``--summary-package``.

    Returns
    -------
    dict[str, str]
        Mapping from display name to normalized lookup package name. Insertion
        order follows the CLI option order.

    Raises
    ------
    click.BadParameter
        If a mapping is malformed or repeats a display name.
    """
    mappings: dict[str, str] = {}
    for raw_mapping in raw_mappings:
        display_name, separator, package_name = raw_mapping.partition("=")
        display_name = display_name.strip()
        package_name = package_name.strip()
        if not separator or not display_name or not package_name:
            raise click.BadParameter(
                f"'{raw_mapping}' is invalid. Use DISPLAY=PACKAGE.",
                param_hint="--summary-package",
            )
        if display_name in mappings:
            raise click.BadParameter(
                f"duplicate display name: {display_name}",
                param_hint="--summary-package",
            )
        mappings[display_name] = package_name
    return mappings


def package_filename_from_url(url_or_path: str) -> str:
    """Extract a package filename from a URL or local path.

    Parameters
    ----------
    url_or_path
        URL or local path recorded in ``pixi.lock``.

    Returns
    -------
    str
        The unquoted package filename.

    Raises
    ------
    click.ClickException
        If the path does not contain a filename.
    """
    parsed = urlparse(url_or_path)
    path = parsed.path if parsed.scheme else url_or_path
    filename = unquote(path.rstrip("/").rsplit("/", 1)[-1])
    if not filename:
        raise click.ClickException(
            f"Package URL/path '{url_or_path}' does not include a filename."
        )
    return filename


def strip_conda_extension(filename: str) -> str:
    """Remove a supported conda package extension.

    Parameters
    ----------
    filename
        Conda package filename.

    Returns
    -------
    str
        Filename stem without ``.conda`` or ``.tar.bz2``.

    Raises
    ------
    click.ClickException
        If the filename does not use a supported conda package extension.
    """
    for suffix in (".tar.bz2", ".conda"):
        if filename.endswith(suffix):
            return filename[: -len(suffix)]
    raise click.ClickException(f"Unsupported conda package filename extension: {filename}")


def parse_conda_package(conda_url: str) -> dict[str, str | None]:
    """Parse a conda package record from a Pixi lock package URL.

    Parameters
    ----------
    conda_url
        Conda package URL from an environment package list.

    Returns
    -------
    dict[str, str | None]
        Environment JSON package record.

    Raises
    ------
    click.ClickException
        If the filename cannot be parsed as ``name-version-build``.
    """
    filename = package_filename_from_url(conda_url)
    stem = strip_conda_extension(filename)
    parts = stem.rsplit("-", 2)
    if len(parts) != 3 or not all(parts):
        raise click.ClickException(
            f"Could not parse conda package filename '{filename}' as name-version-build."
        )

    name, version, build_id = parts
    return {
        "name": name,
        "version": version,
        "buildId": build_id,
        "source": "conda",
    }


def build_package_metadata_index(
    raw_packages: object,
) -> dict[tuple[str, str], dict[str, Any]]:
    """Index top-level lockfile package metadata by source and reference.

    Parameters
    ----------
    raw_packages
        Top-level ``packages`` value from ``pixi.lock``.

    Returns
    -------
    dict[tuple[str, str], dict[str, Any]]
        Mapping keyed by ``("conda"|"pypi", package_reference)``.

    Raises
    ------
    click.ClickException
        If the top-level package metadata is malformed.
    """
    if raw_packages is None:
        return {}
    if not isinstance(raw_packages, list):
        raise click.ClickException("Lockfile packages must be a list when present.")

    index: dict[tuple[str, str], dict[str, Any]] = {}
    for raw_package in raw_packages:
        package = require_dict(raw_package, "Lockfile package")
        for source in ("conda", "pypi"):
            value = package.get(source)
            if isinstance(value, str):
                index[(source, value)] = package
    return index


def parse_pypi_package(
    pypi_url_or_path: str,
    metadata_index: dict[tuple[str, str], dict[str, Any]],
) -> dict[str, str | None]:
    """Parse a PyPI package record using top-level lockfile metadata.

    Parameters
    ----------
    pypi_url_or_path
        PyPI URL or local path from an environment package list.
    metadata_index
        Top-level lockfile package metadata indexed by package reference.

    Returns
    -------
    dict[str, str | None]
        Environment JSON package record.

    Raises
    ------
    click.ClickException
        If metadata is missing or incomplete.
    """
    metadata = metadata_index.get(("pypi", pypi_url_or_path))
    if metadata is None:
        raise click.ClickException(
            f"PyPI package '{pypi_url_or_path}' is missing from lockfile packages metadata."
        )

    name = require_string(metadata.get("name"), f"PyPI package '{pypi_url_or_path}' name")
    version = require_string(
        metadata.get("version"),
        f"PyPI package '{pypi_url_or_path}' version",
    )
    return {
        "name": name,
        "version": version,
        "buildId": None,
        "source": "pypi",
    }


def parse_lock_package(
    raw_package: object,
    metadata_index: dict[tuple[str, str], dict[str, Any]],
) -> dict[str, str | None]:
    """Parse an environment package entry from a Pixi lockfile.

    Parameters
    ----------
    raw_package
        Raw package entry from an environment/platform package list.
    metadata_index
        Top-level lockfile package metadata indexed by package reference.

    Returns
    -------
    dict[str, str | None]
        Environment JSON package record.

    Raises
    ------
    click.ClickException
        If the package source is unsupported or malformed.
    """
    package = require_dict(raw_package, "Environment package entry")
    conda_url = package.get("conda")
    pypi_url_or_path = package.get("pypi")

    if isinstance(conda_url, str):
        return parse_conda_package(conda_url)
    if isinstance(pypi_url_or_path, str):
        return parse_pypi_package(pypi_url_or_path, metadata_index)

    raise click.ClickException(
        f"Unsupported package entry {package!r}. Expected a conda or pypi package reference."
    )


def normalize_package_name(name: str) -> str:
    """Normalize a package name for lookup comparisons.

    Parameters
    ----------
    name
        Package name to normalize.

    Returns
    -------
    str
        Lowercase package name with runs of ``-``, ``_``, and ``.`` collapsed
        to ``-``.
    """
    return re.sub(r"[-_.]+", "-", name).lower()


def build_package_versions(
    summary_mappings: dict[str, str],
    environment_records: list[dict[str, Any]],
) -> dict[str, str | None]:
    """Build the image-level package version summary.

    Parameters
    ----------
    summary_mappings
        Mapping from display name to package name lookup key.
    environment_records
        Generated environment JSON payloads.

    Returns
    -------
    dict[str, str | None]
        Mapping from display name to first matching package version, or
        ``None`` when absent.
    """
    package_versions: dict[str, str] = {}
    for environment_record in environment_records:
        for package in environment_record["packages"]:
            normalized = normalize_package_name(package["name"])
            package_versions.setdefault(normalized, package["version"])

    return {
        display_name: package_versions.get(normalize_package_name(package_name))
        for display_name, package_name in summary_mappings.items()
    }


def build_environment_records(
    lock_data: dict[str, Any],
    selected_environments: list[str],
    image_name: str,
) -> list[tuple[str, str, dict[str, Any]]]:
    """Build environment JSON payloads for selected runtime/test pairs.

    Parameters
    ----------
    lock_data
        Parsed Pixi lockfile.
    selected_environments
        Runtime environment names selected in the Pixi manifest.
    image_name
        Published image name used to construct artifact URLs.

    Returns
    -------
    list[tuple[str, str, dict[str, Any]]]
        Tuples of environment name, platform, and environment JSON payload.

    Raises
    ------
    click.ClickException
        If selected environments or package entries are missing or malformed.
    """
    lock_environments = require_dict(
        lock_data.get("environments"),
        "Lockfile environments",
    )
    metadata_index = build_package_metadata_index(lock_data.get("packages"))

    records: list[tuple[str, str, dict[str, Any]]] = []
    for runtime_environment in selected_environments:
        for env_name in (runtime_environment, f"{runtime_environment}-test"):
            lock_environment = require_dict(
                lock_environments.get(env_name),
                f"Lockfile environment '{env_name}'",
            )
            platform_packages = require_dict(
                lock_environment.get("packages"),
                f"Lockfile environment '{env_name}' packages",
            )
            if not platform_packages:
                raise click.ClickException(
                    f"Lockfile environment '{env_name}' has no platform package lists."
                )

            for platform in sorted(platform_packages):
                raw_packages = platform_packages[platform]
                if not isinstance(raw_packages, list):
                    raise click.ClickException(
                        f"Lockfile environment '{env_name}' platform '{platform}' packages must be a list."
                    )
                environment_slug = f"{env_name}-{platform}"
                packages = [
                    parse_lock_package(package, metadata_index)
                    for package in raw_packages
                ]
                records.append(
                    (
                        env_name,
                        platform,
                        {
                            "environmentYamlUrl": (
                                f"/artifacts/{image_name}/{environment_slug}/"
                                f"{environment_slug}.environment.yaml"
                            ),
                            "packages": packages,
                        },
                    )
                )

    return records


def build_image_record(
    *,
    name: str,
    timestamp: str,
    ami_id: str,
    docker_image: str,
    package_versions: dict[str, str | None],
    environment_records: list[tuple[str, str, dict[str, Any]]],
) -> dict[str, Any]:
    """Build the image JSON payload.

    Parameters
    ----------
    name
        Published image name.
    timestamp
        Published image timestamp.
    ami_id
        Published AMI ID.
    docker_image
        Published Docker image reference.
    package_versions
        Image-level package summary.
    environment_records
        Generated environment payload records.

    Returns
    -------
    dict[str, Any]
        Image JSON payload.
    """
    environments = []
    for env_name, platform, _environment_record in environment_records:
        environment_slug = f"{env_name}-{platform}"
        environments.append(
            {
                "name": env_name,
                "platform": platform,
                "environmentJsonUrl": f"/artifacts/{name}/{environment_slug}.json",
            }
        )

    return {
        "name": name,
        "timestamp": timestamp,
        "amiId": ami_id,
        "dockerImage": docker_image,
        "packageVersions": package_versions,
        "imageJsonUrl": f"/artifacts/{name}/image.json",
        "pixiLockUrl": f"/lockfiles/{name}.pixi.lock",
        "environments": environments,
    }


def write_json(path: Path, payload: object) -> None:
    """Write a JSON payload with deterministic formatting.

    Parameters
    ----------
    path
        Destination file path.
    payload
        JSON-serializable payload to write.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def generate(
    *,
    lockfile: Path,
    manifest: Path,
    output_root: Path,
    name: str,
    timestamp: str,
    ami_id: str,
    docker_image: str,
    summary_package: tuple[str, ...],
) -> list[Path]:
    """Generate image and environment artifact JSON files.

    Parameters
    ----------
    lockfile
        Path to ``pixi.lock``.
    manifest
        Path to the Pixi manifest.
    output_root
        Root directory for generated site artifacts.
    name
        Published image name.
    timestamp
        Published image timestamp.
    ami_id
        Published AMI ID.
    docker_image
        Published Docker image reference.
    summary_package
        Raw ``DISPLAY=PACKAGE`` summary package mappings.

    Returns
    -------
    list[Path]
        Paths written by the generator.
    """
    selected_environments = load_selected_environments(manifest)
    summary_mappings = parse_summary_packages(summary_package)
    lock_data = require_dict(load_yaml(lockfile, "Pixi lockfile"), "Pixi lockfile")

    environment_records = build_environment_records(
        lock_data,
        selected_environments,
        name,
    )
    environment_payloads = [record for _env_name, _platform, record in environment_records]
    package_versions = build_package_versions(summary_mappings, environment_payloads)
    image_payload = build_image_record(
        name=name,
        timestamp=timestamp,
        ami_id=ami_id,
        docker_image=docker_image,
        package_versions=package_versions,
        environment_records=environment_records,
    )

    image_dir = output_root / "artifacts" / name
    written_paths: list[Path] = []
    for env_name, platform, environment_payload in environment_records:
        environment_slug = f"{env_name}-{platform}"
        environment_path = image_dir / f"{environment_slug}.json"
        write_json(environment_path, environment_payload)
        written_paths.append(environment_path)

    image_path = image_dir / "image.json"
    write_json(image_path, image_payload)
    written_paths.append(image_path)
    return written_paths


@click.command()
@click.option(
    "--lockfile",
    required=True,
    type=click.Path(exists=True, dir_okay=False, path_type=Path),
    help="Path to pixi.lock.",
)
@click.option(
    "--manifest",
    required=True,
    type=click.Path(exists=True, dir_okay=False, path_type=Path),
    help="Path to the Pixi manifest with [tool.image-builder] metadata.",
)
@click.option(
    "--output-root",
    default=Path("public"),
    show_default=True,
    type=click.Path(file_okay=False, path_type=Path),
    help="Root directory for generated site artifacts.",
)
@click.option(
    "--name",
    required=True,
    type=NonEmptyString(),
    help="Published image name.",
)
@click.option(
    "--timestamp",
    required=True,
    type=NonEmptyString(),
    help="Published image timestamp in ISO 8601 format, for example 2026-04-03T12:34:56Z.",
)
@click.option(
    "--ami-id",
    required=True,
    type=NonEmptyString(),
    help="Published AMI ID.",
)
@click.option(
    "--docker-image",
    required=True,
    type=NonEmptyString(),
    help="Published Docker image reference.",
)
@click.option(
    "--summary-package",
    multiple=True,
    metavar="DISPLAY=PACKAGE",
    help=(
        "Package summary mapping. DISPLAY is the image JSON key and PACKAGE "
        "is looked up in generated environment packages."
    ),
)
def cli(
    lockfile: Path,
    manifest: Path,
    output_root: Path,
    name: str,
    timestamp: str,
    ami_id: str,
    docker_image: str,
    summary_package: tuple[str, ...],
) -> None:
    """Generate image and environment JSON artifacts from a Pixi lockfile."""
    written_paths = generate(
        lockfile=lockfile,
        manifest=manifest,
        output_root=output_root,
        name=name,
        timestamp=timestamp,
        ami_id=ami_id,
        docker_image=docker_image,
        summary_package=summary_package,
    )

    for path in written_paths:
        click.echo(path)


if __name__ == "__main__":
    cli()
