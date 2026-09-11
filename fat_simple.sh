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

  mkdir -p "$OUT/work" "$OUT/bundle_segmentations" "$OUT/endings_segmentations" "$OUT/iFOD2_trackings" "$OUT/SD_STREAM_trackings" "$TRACTSEG_WEIGHTS_DIR" "$MPLCONFIGDIR" "$XDG_CACHE_HOME"

  # Check peaks/FODs and replace absent NaN peak triplets in a working copy.
  fat_qc inputs --peaks "$IN/peaks.nii.gz" --fod "$IN/wm.nii.gz"
  fat_qc prepare-peaks "$IN/peaks.nii.gz" "$OUT/work/peaks.nii.gz"

  # XTRACT-trained TractSeg model; export only the left/right FAT.
  TractSeg -i "$OUT/work/peaks.nii.gz" -o "$OUT/work/xtract_model" --tract_definition xtract --output_type tract_segmentation --nr_cpus 4
  fat_qc export "$OUT/work/xtract_model/bundle_segmentations/fa_l.nii.gz" "$OUT/work/peaks.nii.gz" "$OUT/bundle_segmentations/FAT_left.nii.gz"
  fat_qc export "$OUT/work/xtract_model/bundle_segmentations/fa_r.nii.gz" "$OUT/work/peaks.nii.gz" "$OUT/bundle_segmentations/FAT_right.nii.gz"

  # Subject-specific geometric end regions; no extra model or training.
  fat_qc endings "$OUT/bundle_segmentations/FAT_left.nii.gz" "$OUT/endings_segmentations/FAT_left_b.nii.gz" "$OUT/endings_segmentations/FAT_left_e.nii.gz"
  fat_qc endings "$OUT/bundle_segmentations/FAT_right.nii.gz" "$OUT/endings_segmentations/FAT_right_b.nii.gz" "$OUT/endings_segmentations/FAT_right_e.nii.gz"

  # ONE -mask: bundle only. Multiple MRtrix masks would form a union!
  # Generate 4000 candidates, then keep 2000 WHOLE tracks entirely inside the mask.
  tckgen "$IN/wm.nii.gz" "$OUT/work/FAT_left_iFOD2.tck" -algorithm iFOD2 -seed_image "$OUT/endings_segmentations/FAT_left_b.nii.gz" -include "$OUT/endings_segmentations/FAT_left_b.nii.gz" -include "$OUT/endings_segmentations/FAT_left_e.nii.gz" -seed_unidirectional -stop -mask "$OUT/bundle_segmentations/FAT_left.nii.gz" -select 4000 -seeds 2000000 -minlength 20 -maxlength 150 -cutoff 0.1 -downsample 1 -nthreads 4
  fat_qc filter-tracks "$OUT/work/FAT_left_iFOD2.tck" "$OUT/bundle_segmentations/FAT_left.nii.gz" "$OUT/iFOD2_trackings/FAT_left.tck" 2000 --endings "$OUT/endings_segmentations/FAT_left_b.nii.gz" "$OUT/endings_segmentations/FAT_left_e.nii.gz"
  tckgen "$IN/wm.nii.gz" "$OUT/work/FAT_right_iFOD2.tck" -algorithm iFOD2 -seed_image "$OUT/endings_segmentations/FAT_right_b.nii.gz" -include "$OUT/endings_segmentations/FAT_right_b.nii.gz" -include "$OUT/endings_segmentations/FAT_right_e.nii.gz" -seed_unidirectional -stop -mask "$OUT/bundle_segmentations/FAT_right.nii.gz" -select 4000 -seeds 2000000 -minlength 20 -maxlength 150 -cutoff 0.1 -downsample 1 -nthreads 4
  fat_qc filter-tracks "$OUT/work/FAT_right_iFOD2.tck" "$OUT/bundle_segmentations/FAT_right.nii.gz" "$OUT/iFOD2_trackings/FAT_right.tck" 2000 --endings "$OUT/endings_segmentations/FAT_right_b.nii.gz" "$OUT/endings_segmentations/FAT_right_e.nii.gz"

  tckgen "$IN/wm.nii.gz" "$OUT/work/FAT_left_SD_STREAM.tck" -algorithm SD_STREAM -seed_image "$OUT/endings_segmentations/FAT_left_b.nii.gz" -include "$OUT/endings_segmentations/FAT_left_b.nii.gz" -include "$OUT/endings_segmentations/FAT_left_e.nii.gz" -seed_unidirectional -stop -mask "$OUT/bundle_segmentations/FAT_left.nii.gz" -select 4000 -seeds 2000000 -minlength 20 -maxlength 150 -cutoff 0.1 -downsample 1 -nthreads 4
  fat_qc filter-tracks "$OUT/work/FAT_left_SD_STREAM.tck" "$OUT/bundle_segmentations/FAT_left.nii.gz" "$OUT/SD_STREAM_trackings/FAT_left.tck" 2000 --endings "$OUT/endings_segmentations/FAT_left_b.nii.gz" "$OUT/endings_segmentations/FAT_left_e.nii.gz"
  tckgen "$IN/wm.nii.gz" "$OUT/work/FAT_right_SD_STREAM.tck" -algorithm SD_STREAM -seed_image "$OUT/endings_segmentations/FAT_right_b.nii.gz" -include "$OUT/endings_segmentations/FAT_right_b.nii.gz" -include "$OUT/endings_segmentations/FAT_right_e.nii.gz" -seed_unidirectional -stop -mask "$OUT/bundle_segmentations/FAT_right.nii.gz" -select 4000 -seeds 2000000 -minlength 20 -maxlength 150 -cutoff 0.1 -downsample 1 -nthreads 4
  fat_qc filter-tracks "$OUT/work/FAT_right_SD_STREAM.tck" "$OUT/bundle_segmentations/FAT_right.nii.gz" "$OUT/SD_STREAM_trackings/FAT_right.tck" 2000 --endings "$OUT/endings_segmentations/FAT_right_b.nii.gz" "$OUT/endings_segmentations/FAT_right_e.nii.gz"

  # Validate saved polylines and both endpoints; no clipping or mask dilation.
  fat_qc tracks "$OUT/iFOD2_trackings/FAT_left.tck" 2000 --mask "$OUT/bundle_segmentations/FAT_left.nii.gz" --endings "$OUT/endings_segmentations/FAT_left_b.nii.gz" "$OUT/endings_segmentations/FAT_left_e.nii.gz"
  fat_qc tracks "$OUT/iFOD2_trackings/FAT_right.tck" 2000 --mask "$OUT/bundle_segmentations/FAT_right.nii.gz" --endings "$OUT/endings_segmentations/FAT_right_b.nii.gz" "$OUT/endings_segmentations/FAT_right_e.nii.gz"
  fat_qc tracks "$OUT/SD_STREAM_trackings/FAT_left.tck" 2000 --mask "$OUT/bundle_segmentations/FAT_left.nii.gz" --endings "$OUT/endings_segmentations/FAT_left_b.nii.gz" "$OUT/endings_segmentations/FAT_left_e.nii.gz"
  fat_qc tracks "$OUT/SD_STREAM_trackings/FAT_right.tck" 2000 --mask "$OUT/bundle_segmentations/FAT_right.nii.gz" --endings "$OUT/endings_segmentations/FAT_right_b.nii.gz" "$OUT/endings_segmentations/FAT_right_e.nii.gz"
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


def derive_endings(mask_path: Path, begin_path: Path, end_path: Path) -> None:
    """Geometric terminal caps; not learned or anatomically labelled endpoints."""
    mask, _ = mask_data(mask_path)
    if begin_path.exists() or end_path.exists():
        raise ValueError("End-region output already exists.")
    voxels = np.argwhere(mask)
    unseen = {tuple(point) for point in voxels}
    stack = [unseen.pop()]
    while stack:
        point = stack.pop()
        for axis in range(3):
            for step in (-1, 1):
                neighbour = list(point)
                neighbour[axis] += step
                key = tuple(neighbour)
                if key in unseen:
                    unseen.remove(key)
                    stack.append(key)
    if unseen:
        raise ValueError("Bundle mask is not face-connected; inspect it before deriving end regions.")
    image = load_nifti(mask_path)
    world = nib.affines.apply_affine(image.affine, voxels)
    _, singular, axes = np.linalg.svd(world - world.mean(axis=0), full_matrices=False)
    if len(singular) < 2 or singular[0] <= 1.5 * singular[1]:
        raise ValueError("Mask has no clear long axis for deriving end regions.")
    direction = axes[0]
    if direction[2] < 0:
        direction = -direction
    projection = (world - world.mean(axis=0)) @ direction
    span = float(np.ptp(projection))
    if span < 10:
        raise ValueError("Mask is too short to derive separated FAT end regions.")
    selections = (projection <= projection.min() + 0.15 * span,
                  projection >= projection.max() - 0.15 * span)
    for path, selected in zip((begin_path, end_path), selections):
        region = np.zeros(mask.shape, dtype=np.uint8)
        region[tuple(voxels[selected].T)] = 1
        nib.save(nib.Nifti1Image(region, image.affine), path)
        print(f"{path.name}: {int(selected.sum())} voxels; geometric terminal 15% of mask long axis.")


def load_endings(mask_path: Path | None, paths: tuple[Path, Path] | None) -> tuple[np.ndarray, np.ndarray] | None:
    if paths is None:
        return None
    if mask_path is None:
        raise ValueError("A bundle mask is required when checking end regions.")
    bundle, _ = mask_data(mask_path)
    regions = []
    for path in paths:
        same_grid(mask_path, path)
        region, _ = mask_data(path)
        region &= bundle
        if not region.any():
            raise ValueError(f"End region does not intersect the bundle mask: {path}")
        regions.append(region)
    if (regions[0] & regions[1]).any():
        raise ValueError("The two end regions overlap inside the bundle mask.")
    return regions[0], regions[1]


def connects_endings(voxel_points: np.ndarray, regions: tuple[np.ndarray, np.ndarray]) -> bool:
    if len(voxel_points) < 2 or not np.isfinite(voxel_points[[0, -1]]).all():
        return False
    cells = np.floor(voxel_points[[0, -1]] + 0.5).astype(int)
    begin, end = regions
    if np.any(cells < 0) or np.any(cells >= np.asarray(begin.shape)):
        return False
    a, b = tuple(cells[0]), tuple(cells[1])
    return bool((begin[a] and end[b]) or (end[a] and begin[b]))


def filter_tracks(source: Path, mask_path: Path, destination: Path, requested: int,
                  endings: tuple[Path, Path] | None = None) -> None:
    """Keep whole tracks only: no clipping, splitting, dilation or duplication."""
    if requested <= 0:
        raise ValueError("Requested streamline count must be positive.")
    if destination.exists():
        raise ValueError(f"Output already exists: {destination}")
    mask, inverse = mask_data(mask_path)
    regions = load_endings(mask_path, endings)
    selected = []
    rejected = 0
    for streamline in nib.streamlines.load(str(source), lazy_load=True).streamlines:
        voxel_points = nib.affines.apply_affine(inverse, streamline)
        connected = regions is None or connects_endings(voxel_points, regions)
        if connected and inside_mask(voxel_points, mask):
            selected.append(streamline)
            if len(selected) == requested:
                break
        else:
            rejected += 1
    if len(selected) != requested:
        raise ValueError(
            f"Only {len(selected)}/{requested} valid streamlines inside {mask_path.name}. "
            "Check end regions, FODs and mask; no incomplete final tractogram written."
        )
    nib.streamlines.save(
        nib.streamlines.Tractogram(selected, affine_to_rasmm=np.eye(4)), str(destination)
    )
    print(f"{destination.name}: retained {requested}; rejected {rejected} tracks failing mask/end-region checks.")


def check_tracks(path: Path, requested: int, mask_path: Path | None = None,
                 endings: tuple[Path, Path] | None = None) -> None:
    tractogram = nib.streamlines.load(str(path), lazy_load=True)
    count = 0
    outside = 0
    disconnected = 0
    regions = load_endings(mask_path, endings)
    if mask_path is not None:
        mask, inverse = mask_data(mask_path)
    for streamline in tractogram.streamlines:
        count += 1
        if mask_path is not None and not inside_mask(nib.affines.apply_affine(inverse, streamline), mask):
            outside += 1
        if regions is not None and not connects_endings(nib.affines.apply_affine(inverse, streamline), regions):
            disconnected += 1
    if count != requested:
        raise ValueError(f"{path}: {count}/{requested} streamlines. Inspect mask/ROIs and seed limit; no silent success.")
    if outside:
        raise ValueError(f"{path}: {outside}/{count} streamlines leave the bundle mask.")
    if disconnected:
        raise ValueError(f"{path}: {disconnected}/{count} streamlines do not start and end in opposite end regions.")
    containment = "; 0 outside (vertices and connecting segments)" if mask_path is not None else ""
    connection = "; all connect opposite end regions" if regions is not None else ""
    print(f"{path.name}: {count} streamlines OK{containment}{connection}")


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
        "Tracking requires both endpoints in opposite end regions, in addition to whole-polyline containment.\n"
        "Default end regions: terminal 15% of the subject mask's physical principal axis; no training.\n"
        "These geometric end regions are not learned anatomical IFG/SMA segmentations; inspect them individually.\n"
        "No learned FAT endings or TOMs. Insufficient valid connections cause failure, not a partial final bundle.\n"
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
    endings = sub.add_parser("endings")
    for name in ("mask", "begin", "end"):
        endings.add_argument(name, type=Path)
    tracks = sub.add_parser("tracks")
    tracks.add_argument("path", type=Path)
    tracks.add_argument("requested", type=int)
    tracks.add_argument("--mask", type=Path)
    tracks.add_argument("--endings", nargs=2, type=Path, metavar=("BEGIN", "END"))
    filtering = sub.add_parser("filter-tracks")
    for name in ("source", "mask", "destination"):
        filtering.add_argument(name, type=Path)
    filtering.add_argument("requested", type=int)
    filtering.add_argument("--endings", nargs=2, type=Path, metavar=("BEGIN", "END"))
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
    elif args.command == "endings":
        derive_endings(args.mask, args.begin, args.end)
    elif args.command == "tracks":
        end_paths = (args.endings[0], args.endings[1]) if args.endings else None
        check_tracks(args.path, args.requested, args.mask, end_paths)
    elif args.command == "filter-tracks":
        end_paths = (args.endings[0], args.endings[1]) if args.endings else None
        filter_tracks(args.source, args.mask, args.destination, args.requested, end_paths)
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
