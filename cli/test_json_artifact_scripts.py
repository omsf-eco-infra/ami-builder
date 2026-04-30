import json
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
JSONLOCKFILE_SCRIPT = REPO_ROOT / "cli" / "jsonlockfile.py"
UPDATE_MANIFEST_SCRIPT = REPO_ROOT / "cli" / "update_manifest.py"


def write_pixi_manifest(tmp_path: Path) -> Path:
    manifest_path = tmp_path / "pixi.toml"
    manifest_path.write_text(
        "\n".join(
            [
                "[workspace]",
                'name = "test"',
                'channels = ["conda-forge"]',
                'platforms = ["linux-64"]',
                "",
                "[tool.image-builder]",
                'image_name = "test"',
                'default_environment = "openfe"',
                'environments = ["openfe"]',
                "",
                "[environments.openfe]",
                'features = ["openfe"]',
                'no-default-feature = true',
                "",
                "[environments.openfe-test]",
                'features = ["openfe", "openfe-test"]',
                'no-default-feature = true',
                "",
                "[environments.skipped]",
                'features = ["skipped"]',
                'no-default-feature = true',
                "",
                "[environments.skipped-test]",
                'features = ["skipped", "skipped-test"]',
                'no-default-feature = true',
                "",
            ]
        ),
        encoding="utf-8",
    )
    return manifest_path


def write_pixi_lock(tmp_path: Path) -> Path:
    lock_path = tmp_path / "pixi.lock"
    lock_path.write_text(
        "\n".join(
            [
                "version: 6",
                "environments:",
                "  default:",
                "    packages: {}",
                "  openfe:",
                "    packages:",
                "      linux-64:",
                "      - conda: https://conda.anaconda.org/conda-forge/noarch/openfe-1.2.3-pyhd8ed1ab_0.conda",
                "      - conda: https://conda.anaconda.org/conda-forge/noarch/cached-property-1.5.2-hd8ed1ab_1.tar.bz2",
                "      - pypi: https://files.pythonhosted.org/packages/example-pkg-2.0.0-py3-none-any.whl",
                "  openfe-test:",
                "    packages:",
                "      linux-64:",
                "      - conda: https://conda.anaconda.org/conda-forge/noarch/pytest-9.0.0-pyhcf101f3_0.conda",
                "      - pypi: ../local-project",
                "  skipped:",
                "    packages:",
                "      linux-64:",
                "      - conda: https://conda.anaconda.org/conda-forge/noarch/skipped-0.1.0-pyhd8ed1ab_0.conda",
                "  skipped-test:",
                "    packages:",
                "      linux-64:",
                "      - conda: https://conda.anaconda.org/conda-forge/noarch/skipped-test-0.1.0-pyhd8ed1ab_0.conda",
                "packages:",
                "- pypi: https://files.pythonhosted.org/packages/example-pkg-2.0.0-py3-none-any.whl",
                "  name: example-pkg",
                "  version: 2.0.0",
                "  sha256: abc",
                "- pypi: ../local-project",
                "  name: local-project",
                "  version: 0.1.0",
                "  sha256: def",
                "",
            ]
        ),
        encoding="utf-8",
    )
    return lock_path


def run_jsonlockfile(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(JSONLOCKFILE_SCRIPT), *args],
        check=True,
        capture_output=True,
        text=True,
    )


def run_update_manifest(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(UPDATE_MANIFEST_SCRIPT), *args],
        check=True,
        capture_output=True,
        text=True,
    )


def run_update_manifest_error(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(UPDATE_MANIFEST_SCRIPT), *args],
        check=False,
        capture_output=True,
        text=True,
    )


def test_jsonlockfile_generates_site_layout_json_from_selected_environments(tmp_path):
    manifest_path = write_pixi_manifest(tmp_path)
    lock_path = write_pixi_lock(tmp_path)
    output_root = tmp_path / "public"

    run_jsonlockfile(
        "--lockfile",
        str(lock_path),
        "--manifest",
        str(manifest_path),
        "--output-root",
        str(output_root),
        "--name",
        "openfe-2026-04-03",
        "--timestamp",
        "2026-04-03T12:34:56Z",
        "--ami-id",
        "ami-123",
        "--docker-image",
        "ghcr.io/omsf/openfe:2026-04-03",
        "--summary-package",
        "OpenFE=openfe",
        "--summary-package",
        "Example Package=example_pkg",
        "--summary-package",
        "Missing=missing-package",
    )

    image_dir = output_root / "artifacts" / "openfe-2026-04-03"
    image_json = json.loads((image_dir / "image.json").read_text(encoding="utf-8"))
    runtime_json = json.loads(
        (image_dir / "openfe-linux-64.json").read_text(encoding="utf-8")
    )
    test_json = json.loads(
        (image_dir / "openfe-test-linux-64.json").read_text(encoding="utf-8")
    )

    assert image_json == {
        "name": "openfe-2026-04-03",
        "timestamp": "2026-04-03T12:34:56Z",
        "amiId": "ami-123",
        "dockerImage": "ghcr.io/omsf/openfe:2026-04-03",
        "packageVersions": {
            "OpenFE": "1.2.3",
            "Example Package": "2.0.0",
            "Missing": None,
        },
        "imageJsonUrl": "/artifacts/openfe-2026-04-03/image.json",
        "pixiLockUrl": "/lockfiles/openfe-2026-04-03.pixi.lock",
        "environments": [
            {
                "name": "openfe",
                "platform": "linux-64",
                "environmentJsonUrl": "/artifacts/openfe-2026-04-03/openfe-linux-64.json",
            },
            {
                "name": "openfe-test",
                "platform": "linux-64",
                "environmentJsonUrl": "/artifacts/openfe-2026-04-03/openfe-test-linux-64.json",
            },
        ],
    }
    assert runtime_json["environmentYamlUrl"] == (
        "/artifacts/openfe-2026-04-03/openfe-linux-64/"
        "openfe-linux-64.environment.yaml"
    )
    assert test_json["environmentYamlUrl"] == (
        "/artifacts/openfe-2026-04-03/openfe-test-linux-64/"
        "openfe-test-linux-64.environment.yaml"
    )
    assert not (image_dir / "skipped-linux-64.json").exists()

    runtime_packages = {package["name"]: package for package in runtime_json["packages"]}
    assert runtime_packages["openfe"] == {
        "name": "openfe",
        "version": "1.2.3",
        "buildId": "pyhd8ed1ab_0",
        "source": "conda",
    }
    assert runtime_packages["cached-property"] == {
        "name": "cached-property",
        "version": "1.5.2",
        "buildId": "hd8ed1ab_1",
        "source": "conda",
    }
    assert runtime_packages["example-pkg"] == {
        "name": "example-pkg",
        "version": "2.0.0",
        "buildId": None,
        "source": "pypi",
    }
    assert test_json["packages"][1] == {
        "name": "local-project",
        "version": "0.1.0",
        "buildId": None,
        "source": "pypi",
    }


def image_record(name: str = "new-image") -> dict[str, object]:
    return {
        "name": name,
        "timestamp": "2026-04-03T12:34:56Z",
        "amiId": "ami-123",
        "dockerImage": "ghcr.io/omsf/openfe:2026-04-03",
        "packageVersions": {"OpenFE": "1.2.3"},
        "imageJsonUrl": f"/artifacts/{name}/image.json",
        "pixiLockUrl": f"/lockfiles/{name}.pixi.lock",
        "environments": [
            {
                "name": "openfe",
                "platform": "linux-64",
                "environmentJsonUrl": f"/artifacts/{name}/openfe-linux-64.json",
            }
        ],
    }


def manifest_summary(name: str = "old-image") -> dict[str, object]:
    image = image_record(name)
    return {
        "name": image["name"],
        "timestamp": image["timestamp"],
        "amiId": image["amiId"],
        "dockerImage": image["dockerImage"],
        "packageVersions": image["packageVersions"],
        "imageJsonUrl": image["imageJsonUrl"],
    }


def test_update_manifest_appends_image_summary(tmp_path):
    manifest_path = tmp_path / "manifest.json"
    image_json_path = tmp_path / "image.json"
    manifest_path.write_text(
        json.dumps([manifest_summary("old-image")]) + "\n",
        encoding="utf-8",
    )
    image_json_path.write_text(
        json.dumps(image_record("new-image")) + "\n",
        encoding="utf-8",
    )

    run_update_manifest(
        "--manifest",
        str(manifest_path),
        "--image-json",
        str(image_json_path),
    )

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert manifest == [manifest_summary("old-image"), manifest_summary("new-image")]


def test_update_manifest_fails_on_duplicate_name_without_rewriting(tmp_path):
    manifest_path = tmp_path / "manifest.json"
    image_json_path = tmp_path / "image.json"
    manifest_path.write_text(
        json.dumps([manifest_summary("new-image")], indent=2) + "\n",
        encoding="utf-8",
    )
    image_json_path.write_text(
        json.dumps(image_record("new-image")) + "\n",
        encoding="utf-8",
    )
    original_manifest = manifest_path.read_text(encoding="utf-8")

    result = run_update_manifest_error(
        "--manifest",
        str(manifest_path),
        "--image-json",
        str(image_json_path),
    )

    assert result.returncode == 1
    assert "already contains image 'new-image'" in result.stderr
    assert manifest_path.read_text(encoding="utf-8") == original_manifest


def test_update_manifest_rejects_non_array_manifest_without_rewriting(tmp_path):
    manifest_path = tmp_path / "manifest.json"
    image_json_path = tmp_path / "image.json"
    manifest_path.write_text(json.dumps({"name": "broken"}) + "\n", encoding="utf-8")
    image_json_path.write_text(
        json.dumps(image_record("new-image")) + "\n",
        encoding="utf-8",
    )
    original_manifest = manifest_path.read_text(encoding="utf-8")

    result = run_update_manifest_error(
        "--manifest",
        str(manifest_path),
        "--image-json",
        str(image_json_path),
    )

    assert result.returncode == 1
    assert "Global manifest must be a JSON array" in result.stderr
    assert manifest_path.read_text(encoding="utf-8") == original_manifest
