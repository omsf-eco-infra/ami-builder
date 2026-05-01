#!/usr/bin/env python3
"""
Non-interactive OpenFold3 setup for smoke testing.

This script configures an explicit cache location, downloads only the default
checkpoint when it is missing, refreshes the Biotite CCD file, and exits
without running the repo's interactive integration test flow.
"""

from __future__ import annotations

import os
from pathlib import Path

import biotite.setup_ccd

from openfold3.core.utils.s3 import download_s3_file, s3_file_matches_local
from openfold3.entry_points.parameters import (
    DEFAULT_CHECKPOINT_NAME,
    OPENFOLD_MODEL_CHECKPOINT_REGISTRY,
    download_model_parameters,
)

S3_BUCKET = "openfold3-data"
S3_KEY = "components.bcif"


def resolve_openfold_paths() -> tuple[Path, Path, Path]:
    cache_dir = Path(
        os.environ.get("OPENFOLD_CACHE", str(Path.home() / ".openfold3"))
    ).expanduser()
    param_dir = Path(
        os.environ.get("OPENFOLD_PARAMETER_DIR", str(cache_dir / "checkpoints"))
    ).expanduser()
    ckpt_root_file = cache_dir / "ckpt_root"

    cache_dir.mkdir(parents=True, exist_ok=True)
    param_dir.mkdir(parents=True, exist_ok=True)
    ckpt_root_file.write_text(str(param_dir))
    os.environ["OPENFOLD_CACHE"] = str(cache_dir)

    return cache_dir, param_dir, ckpt_root_file


def ensure_default_checkpoint(param_dir: Path) -> None:
    checkpoint_file_name = OPENFOLD_MODEL_CHECKPOINT_REGISTRY[
        DEFAULT_CHECKPOINT_NAME
    ].file_name
    checkpoint_path = param_dir / checkpoint_file_name

    if checkpoint_path.exists():
        print(f"[openfold3-smoke] Default checkpoint already present at {checkpoint_path}")
        return

    print(
        "[openfold3-smoke] Downloading default checkpoint "
        f"'{DEFAULT_CHECKPOINT_NAME}' to {param_dir}"
    )
    download_model_parameters(
        param_dir,
        DEFAULT_CHECKPOINT_NAME,
        force_download=False,
        skip_confirmation=True,
    )


def ensure_biotite_ccd() -> None:
    ccd_path = Path(biotite.setup_ccd.OUTPUT_CCD)
    if not ccd_path.exists() or not s3_file_matches_local(ccd_path, S3_BUCKET, S3_KEY):
        print(f"[openfold3-smoke] Updating CCD file at {ccd_path}")
        download_s3_file(S3_BUCKET, S3_KEY, ccd_path)
    else:
        print(f"[openfold3-smoke] CCD file already up to date at {ccd_path}")


def main() -> None:
    cache_dir, param_dir, _ = resolve_openfold_paths()
    print(f"[openfold3-smoke] OPENFOLD_CACHE={cache_dir}")
    print(f"[openfold3-smoke] OPENFOLD_PARAMETER_DIR={param_dir}")
    ensure_default_checkpoint(param_dir)
    ensure_biotite_ccd()


if __name__ == "__main__":
    main()
