#!/usr/bin/env bash
# Workflow author: Lucius Fekonja
# Standalone FAT workflow: share this file alone; the Python helper is embedded.
# Requires TractSeg, MRtrix3, and Python 3 with NumPy/NiBabel on PATH.
# Usage: IN=/path/to/5_dwi OUT=/path/to/new_output bash fat_simple.sh
# Defaults are relative to the working directory: IN=mri, OUT=fat_output.
set -euo pipefail

run_fat_pipeline() {
  IN="${IN:-mri}"
  OUT="${OUT:-fat_output}"
  [[ ! -e "$OUT" ]] || { echo "Output already exists: $OUT" >&2; exit 1; }
  export TRACTSEG_WEIGHTS_DIR="${TRACTSEG_WEIGHTS_DIR:-$PWD/weights}"
  export OMP_NUM_THREADS=4
  export MPLCONFIGDIR="$OUT/work/matplotlib"
  export XDG_CACHE_HOME="$OUT/work/cache"

  mkdir -p "$OUT/work" "$OUT/bundle_segmentations" "$OUT/iFOD2_trackings" "$OUT/SD_STREAM_trackings" "$TRACTSEG_WEIGHTS_DIR" "$MPLCONFIGDIR" "$XDG_CACHE_HOME"

  # Check peaks/FODs and replace absent NaN peak triplets in a working copy.
  fat_qc inputs --peaks "$IN/peaks.nii.gz" --fod "$IN/wm.nii.gz"
  fat_qc prepare-peaks "$IN/peaks.nii.gz" "$OUT/work/peaks.nii.gz"

  # XTRACT-trained TractSeg model; export only the left/right FAT.
  TractSeg -i "$OUT/work/peaks.nii.gz" -o "$OUT/work/xtract_model" --tract_definition xtract --output_type tract_segmentation --nr_cpus 4
  fat_qc export "$OUT/work/xtract_model/bundle_segmentations/fa_l.nii.gz" "$OUT/work/peaks.nii.gz" "$OUT/bundle_segmentations/FAT_left.nii.gz"
  fat_qc export "$OUT/work/xtract_model/bundle_segmentations/fa_r.nii.gz" "$OUT/work/peaks.nii.gz" "$OUT/bundle_segmentations/FAT_right.nii.gz"

  # ONE -mask: bundle only. Multiple MRtrix masks would form a union!
  # Generate 4000 candidates, then keep 2000 WHOLE tracks entirely inside the mask.
  tckgen "$IN/wm.nii.gz" "$OUT/work/FAT_left_iFOD2.tck" -algorithm iFOD2 -seed_image "$OUT/bundle_segmentations/FAT_left.nii.gz" -mask "$OUT/bundle_segmentations/FAT_left.nii.gz" -select 4000 -seeds 2000000 -minlength 20 -maxlength 150 -cutoff 0.1 -downsample 1 -nthreads 4
  tckgen "$IN/wm.nii.gz" "$OUT/work/FAT_right_iFOD2.tck" -algorithm iFOD2 -seed_image "$OUT/bundle_segmentations/FAT_right.nii.gz" -mask "$OUT/bundle_segmentations/FAT_right.nii.gz" -select 4000 -seeds 2000000 -minlength 20 -maxlength 150 -cutoff 0.1 -downsample 1 -nthreads 4
  fat_qc filter-tracks "$OUT/work/FAT_left_iFOD2.tck" "$OUT/bundle_segmentations/FAT_left.nii.gz" "$OUT/iFOD2_trackings/FAT_left.tck" 2000
  fat_qc filter-tracks "$OUT/work/FAT_right_iFOD2.tck" "$OUT/bundle_segmentations/FAT_right.nii.gz" "$OUT/iFOD2_trackings/FAT_right.tck" 2000

  tckgen "$IN/wm.nii.gz" "$OUT/work/FAT_left_SD_STREAM.tck" -algorithm SD_STREAM -seed_image "$OUT/bundle_segmentations/FAT_left.nii.gz" -mask "$OUT/bundle_segmentations/FAT_left.nii.gz" -select 4000 -seeds 2000000 -minlength 20 -maxlength 150 -cutoff 0.1 -downsample 1 -nthreads 4
  tckgen "$IN/wm.nii.gz" "$OUT/work/FAT_right_SD_STREAM.tck" -algorithm SD_STREAM -seed_image "$OUT/bundle_segmentations/FAT_right.nii.gz" -mask "$OUT/bundle_segmentations/FAT_right.nii.gz" -select 4000 -seeds 2000000 -minlength 20 -maxlength 150 -cutoff 0.1 -downsample 1 -nthreads 4
  fat_qc filter-tracks "$OUT/work/FAT_left_SD_STREAM.tck" "$OUT/bundle_segmentations/FAT_left.nii.gz" "$OUT/SD_STREAM_trackings/FAT_left.tck" 2000
  fat_qc filter-tracks "$OUT/work/FAT_right_SD_STREAM.tck" "$OUT/bundle_segmentations/FAT_right.nii.gz" "$OUT/SD_STREAM_trackings/FAT_right.tck" 2000

  # Validate final files after saving; no clipping or mask dilation.
  fat_qc tracks "$OUT/iFOD2_trackings/FAT_left.tck" 2000 --mask "$OUT/bundle_segmentations/FAT_left.nii.gz"
  fat_qc tracks "$OUT/iFOD2_trackings/FAT_right.tck" 2000 --mask "$OUT/bundle_segmentations/FAT_right.nii.gz"
  fat_qc tracks "$OUT/SD_STREAM_trackings/FAT_left.tck" 2000 --mask "$OUT/bundle_segmentations/FAT_left.nii.gz"
  fat_qc tracks "$OUT/SD_STREAM_trackings/FAT_right.tck" 2000 --mask "$OUT/bundle_segmentations/FAT_right.nii.gz"
  fat_qc summary "$OUT"
  touch "$OUT/SUCCESS"
}

# Embedded Python helper. No external scripts/ directory or temporary helper file.
fat_qc() {
  python3 - "$@" <<'FAT_QC_PY'
"""Small input/output checks; no anatomical inference or model reimplementation."""

import argparse
import csv
import math
from pathlib import Path
import subprocess
import sys

import nibabel as nib
import numpy as np


def load_nifti(path: Path) -> nib.Nifti1Image:
    img = nib.load(path)
    if not isinstance(img, nib.Nifti1Image):
        raise ValueError(f"Expected a NIfTI-1 image: {path}")
    return img


def geometry(path: Path) -> tuple[tuple[int, ...], np.ndarray]:
    if not path.is_file():
        raise ValueError(f"Missing input: {path}")
    result = subprocess.run(
        ["mrinfo", str(path), "-size", "-spacing", "-transform"],
        check=True, capture_output=True, text=True,
    )
    lines = result.stdout.strip().splitlines()
    shape = tuple(int(x) for x in lines[0].split())
    spacing = np.array([float(x) for x in lines[1].split()][:3])
    affine = np.array([[float(x) for x in row.split()] for row in lines[2:6]])
    affine[:3, :3] *= spacing
    if affine.shape != (4, 4) or not np.isfinite(affine).all():
        raise ValueError(f"Invalid geometry: {path}")
    return shape, affine


def same_grid(reference: Path, other: Path) -> None:
    shape, affine = geometry(reference)
    other_shape, other_affine = geometry(other)
    if shape[:3] != other_shape[:3] or not np.allclose(affine, other_affine, atol=1e-3, rtol=0):
        raise ValueError(f"Grid mismatch: {reference} versus {other}. Register/resample explicitly first.")


def clean_peaks(data: np.ndarray) -> np.ndarray:
    """MRtrix represents absent peaks by complete NaN triplets."""
    vectors = data.reshape(-1, 3)
    missing = np.isnan(vectors)
    if np.isinf(vectors).any() or np.any(missing.any(axis=1) != missing.all(axis=1)):
        raise ValueError("Peaks contain Inf or partially NaN vectors.")
    cleaned = np.nan_to_num(data)
    if not np.any(cleaned):
        raise ValueError("Peaks are empty.")
    return cleaned


def validate_inputs(peaks: Path | None, fod: Path | None, scalars: list[Path]) -> None:
    reference = peaks or fod
    if reference is None:
        raise ValueError("Peaks or FODs required.")
    if peaks is not None:
        shape, _ = geometry(peaks)
        if len(shape) != 4 or shape[3] != 9:
            raise ValueError("Peaks must have exactly 9 volumes (three MRtrix vectors).")
        data = np.asanyarray(load_nifti(peaks).dataobj)
        clean_peaks(data)
    if fod is not None:
        shape, _ = geometry(fod)
        valid_coefficients = {(order + 1) * (order + 2) // 2 for order in range(2, 18, 2)}
        if len(shape) != 4 or shape[3] not in valid_coefficients:
            raise ValueError("WM input must contain even-order MRtrix SH coefficients, not a WM mask or peaks.")
        same_grid(reference, fod)
    for scalar in scalars:
        shape, _ = geometry(scalar)
        if len(shape) != 3:
            raise ValueError(f"Expected a 3D scalar/mask: {scalar}")
        same_grid(reference, scalar)
    print("Input dimensions and grids OK.")


def export_mask(source: Path, reference: Path, destination: Path) -> None:
    same_grid(reference, source)
    img = load_nifti(source)
    data = np.asanyarray(img.dataobj)
    if data.ndim != 3 or not np.isfinite(data).all() or not np.isin(data, [0, 1]).all():
        raise ValueError(f"Invalid binary FAT segmentation: {source}")
    if not np.any(data):
        raise ValueError(f"Empty FAT segmentation: {source}. Inspect input orientation and image quality.")
    nib.save(nib.Nifti1Image(data.astype(np.uint8), img.affine), destination)
    print(f"{destination.name}: {np.count_nonzero(data)} voxels")


def inside_mask(voxel_points: np.ndarray, mask: np.ndarray) -> bool:
    """Check the full polyline against voxel cells, including between vertices.

    NIfTI indices locate voxel centres. Shift by 0.5 so voxel faces are integers,
    then inspect each interval between successive plane crossings. Unlike point
    sampling at a fixed step, this also detects arbitrarily short corner crossings.
    """
    if len(voxel_points) < 2 or not np.isfinite(voxel_points).all():
        return False
    shifted = np.asarray(voxel_points, dtype=np.float64) + 0.5
    cells = np.floor(shifted).astype(np.int64)
    if np.any(cells < 0) or np.any(cells >= np.asarray(mask.shape)):
        return False
    if not mask[tuple(cells.T)].all():
        return False
    changed = np.flatnonzero(np.any(np.diff(cells, axis=0), axis=1))
    for index in changed:
        start, end = shifted[index:index + 2]
        delta = end - start
        times = [0.0, 1.0]
        for axis in range(3):
            if delta[axis] == 0:
                continue
            lower, upper = sorted((start[axis], end[axis]))
            planes = np.arange(math.floor(lower) + 1, math.ceil(upper))
            times.extend(((planes - start[axis]) / delta[axis]).tolist())
        crossings = np.unique(times)
        midpoints = (crossings[:-1] + crossings[1:]) / 2
        traversed = np.floor(start + midpoints[:, None] * delta).astype(np.int64)
        if not mask[tuple(traversed.T)].all():
            return False
    return True


def mask_data(path: Path) -> tuple[np.ndarray, np.ndarray]:
    img = load_nifti(path)
    data = np.asanyarray(img.dataobj)
    if data.ndim != 3 or not np.isin(data, [0, 1]).all() or not data.any():
        raise ValueError(f"Expected a nonempty binary mask: {path}")
    return data.astype(bool), np.linalg.inv(img.affine)


def filter_tracks(source: Path, mask_path: Path, destination: Path, requested: int) -> None:
    """Keep whole tracks only: no clipping, splitting, dilation or duplication."""
    if requested <= 0:
        raise ValueError("Requested streamline count must be positive.")
    if destination.exists():
        raise ValueError(f"Output already exists: {destination}")
    mask, inverse = mask_data(mask_path)
    selected = []
    rejected = 0
    for streamline in nib.streamlines.load(str(source), lazy_load=True).streamlines:
        if inside_mask(nib.affines.apply_affine(inverse, streamline), mask):
            selected.append(streamline)
            if len(selected) == requested:
                break
        else:
            rejected += 1
    if len(selected) != requested:
        raise ValueError(
            f"Only {len(selected)}/{requested} complete streamlines inside {mask_path.name}. "
            "Generate more candidates; no incomplete final tractogram written."
        )
    nib.streamlines.save(
        nib.streamlines.Tractogram(selected, affine_to_rasmm=np.eye(4)), str(destination)
    )
    print(f"{destination.name}: retained {requested}; rejected {rejected} tracks leaving the mask.")


def check_tracks(path: Path, requested: int, mask_path: Path | None = None) -> None:
    tractogram = nib.streamlines.load(str(path), lazy_load=True)
    count = 0
    outside = 0
    if mask_path is not None:
        mask, inverse = mask_data(mask_path)
    for streamline in tractogram.streamlines:
        count += 1
        if mask_path is not None and not inside_mask(nib.affines.apply_affine(inverse, streamline), mask):
            outside += 1
    if count != requested:
        raise ValueError(f"{path}: {count}/{requested} streamlines. Inspect mask/ROIs and seed limit; no silent success.")
    if outside:
        raise ValueError(f"{path}: {outside}/{count} streamlines leave the bundle mask.")
    containment = "; 0 outside (vertices and connecting segments)" if mask_path is not None else ""
    print(f"{path.name}: {count} streamlines OK{containment}")


def summary(out: Path) -> None:
    with (out / "qc_summary.csv").open("w", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["bundle", "segmentation_voxels", "segmentation_volume_mm3"])
        for name in ("FAT_left", "FAT_right"):
            img = load_nifti(out / "bundle_segmentations" / f"{name}.nii.gz")
            voxels = int(np.count_nonzero(np.asanyarray(img.dataobj)))
            volume = voxels * abs(np.linalg.det(img.affine[:3, :3]))
            writer.writerow([name, voxels, f"{volume:.3f}"])
    (out / "METHOD.txt").write_text(
        "Segmentation: TractSeg --tract_definition xtract; fa_l=FAT_left, fa_r=FAT_right.\n"
        "Optional streamlines: MRtrix with ONE undilated bundle mask; see pipeline.log for ROI constraints.\n"
        "Whole streamlines leaving the mask are rejected; all vertices AND connecting segments are checked.\n"
        "No learned FAT endings or TOMs. No full endpoint-to-endpoint reconstruction is guaranteed.\n"
        "Mean FA CSVs: one mean per streamline, NOT spatially corresponding along-tract profiles.\n"
        "Densities from dm_regression are model predictions, not measured streamline counts.\n"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    parameters = sub.add_parser("parameters")
    parameters.add_argument("minimum", type=float)
    parameters.add_argument("maximum", type=float)
    parameters.add_argument("cutoff", type=float)
    inputs = sub.add_parser("inputs")
    inputs.add_argument("--peaks", type=Path)
    inputs.add_argument("--fod", type=Path)
    inputs.add_argument("--scalar", type=Path, action="append", default=[])
    export = sub.add_parser("export")
    for name in ("source", "reference", "destination"):
        export.add_argument(name, type=Path)
    prepare = sub.add_parser("prepare-peaks")
    prepare.add_argument("source", type=Path)
    prepare.add_argument("destination", type=Path)
    tracks = sub.add_parser("tracks")
    tracks.add_argument("path", type=Path)
    tracks.add_argument("requested", type=int)
    tracks.add_argument("--mask", type=Path)
    filtering = sub.add_parser("filter-tracks")
    for name in ("source", "mask", "destination"):
        filtering.add_argument(name, type=Path)
    filtering.add_argument("requested", type=int)
    sub.add_parser("summary").add_argument("out", type=Path)
    args = parser.parse_args()
    if args.command == "parameters":
        if not all(math.isfinite(x) for x in (args.minimum, args.maximum, args.cutoff)):
            raise ValueError("Tracking parameters must be finite.")
        if not 0 < args.minimum < args.maximum or args.cutoff <= 0:
            raise ValueError("Require 0 < MIN_LENGTH < MAX_LENGTH and CUTOFF > 0.")
    elif args.command == "inputs":
        validate_inputs(args.peaks, args.fod, args.scalar)
    elif args.command == "export":
        export_mask(args.source, args.reference, args.destination)
    elif args.command == "prepare-peaks":
        img = load_nifti(args.source)
        data = clean_peaks(np.asanyarray(img.dataobj))
        nib.save(nib.Nifti1Image(data.astype(np.float32), img.affine), args.destination)
    elif args.command == "tracks":
        check_tracks(args.path, args.requested, args.mask)
    elif args.command == "filter-tracks":
        filter_tracks(args.source, args.mask, args.destination, args.requested)
    else:
        summary(args.out)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
FAT_QC_PY
}

# Sourcing only defines functions, allowing isolated checks without inference.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_fat_pipeline
fi
