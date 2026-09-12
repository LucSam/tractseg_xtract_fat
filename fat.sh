#!/usr/bin/env bash
# Author: Lucius Fekonja
# HCP1065 atlas: Yeh (2022), doi:10.1038/s41467-022-32595-4, CC BY-SA 4.0.

usage() {
  cat <<'EOF'
Usage: bash fat.sh --input MRI_DIR [options]
       bash fat.sh --setup-atlas [--atlas-dir DIR]

  --input, -i DIR          Folder containing wm.nii.gz/wm.mif and t1_brain.nii.gz
  --output, -o DIR         New output directory (default: MRI_DIR/fat_output)
  --algorithm, -a NAME     iFOD2 (default), SD_STREAM, FACT, Tensor_Det, Tensor_Prob
                          Use commas to select several algorithms.
  --streamlines, -n N      Final streamlines per side and algorithm (2000)
  --cutoff FLOAT          FOD/peak amplitude cutoff (0.05)
  --tensor-fa FLOAT       Tensor FA cutoff (0.1)
  --min-length MM        Minimum streamline length (20)
  --max-length MM        Maximum streamline length (150)
  --threads N            CPU threads (4)
  --max-seeds N          Maximum seed attempts per side/algorithm (2000000)
  --candidates N         Candidates per side (2 x streamlines; 4 x for tensors)
  --mask-threshold FLOAT HCP1065 probability threshold (0.05)
  --mask-margin MM       Bundle mask margin (3)
  --roi-margin MM        Cortical end-region margin (3)
  --dwi FILE             DWI .mif with gradients for tensor tracking
                         (default: MRI_DIR/dwi_den_unr_pre_unbia.mif)
  --t1 FILE              Brain-extracted T1 (default: MRI_DIR/t1_brain.nii.gz)
  --atlas-dir DIR        Installed atlas directory
                         (default: ~/.cache/tractseg_xtract_fat/hcp1065)
  --fsl-dir DIR          FSL installation (default: FSLDIR)
  --t1-to-mni-prefix P   Reuse ANTs T1-to-FSL-MNI152 transforms
  --t1-to-icbm-prefix P  Reuse ANTs T1-to-ICBM2009a transforms
  --t1-to-dwi-affine F   Reuse ANTs rigid T1-to-DWI transform
  --setup-atlas          Download, verify and prepare atlas files; then exit
  --check                Check prerequisites and inputs; then exit
  --dry-run              Check inputs and print commands without creating output
  --help, -h             Show this help
EOF
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command missing: $1"; }
run() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  if [[ "$mode" != dry-run ]]; then
    { printf '+'; printf ' %q' "$@"; printf '\n'; } >> "$out/commands.log"
    "$@"
  fi
}

run_fat_pipeline() {
  set -euo pipefail
  local input="" out="" mode=run algorithm_list=iFOD2
  local streamlines=2000 cutoff=0.05 tensor_fa=0.1 min_length=20 max_length=150
  local threads=4 max_seeds=2000000 candidates="" mask_threshold=0.05 mask_margin=3 roi_margin=3
  local t1="" dwi="" atlas_dir="${HOME}/.cache/tractseg_xtract_fat/hcp1065" fsl_dir="${FSLDIR:-}"
  local mni_prefix="" icbm_prefix="" dwi_affine="" value algorithm
  local -a algorithms atlas_args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h) usage; return ;;
      --setup-atlas|--check|--dry-run)
        [[ "$mode" == run ]] || die 'Choose one of --setup-atlas, --check or --dry-run.'
        mode="${1#--}"; shift; continue ;;
      --input|-i|--output|-o|--algorithm|-a|--streamlines|-n|--cutoff|--tensor-fa|--min-length|--max-length|--threads|--max-seeds|--candidates|--mask-threshold|--mask-margin|--roi-margin|--dwi|--t1|--atlas-dir|--fsl-dir|--t1-to-mni-prefix|--t1-to-icbm-prefix|--t1-to-dwi-affine)
        [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "Value missing for $1"
        value="$2" ;;
      *) die "Unknown option: $1. Use --help." ;;
    esac
    case "$1" in
      --input|-i) input="$value" ;; --output|-o) out="$value" ;;
      --algorithm|-a) algorithm_list="$value" ;; --streamlines|-n) streamlines="$value" ;;
      --cutoff) cutoff="$value" ;; --tensor-fa) tensor_fa="$value" ;;
      --min-length) min_length="$value" ;; --max-length) max_length="$value" ;;
      --threads) threads="$value" ;; --max-seeds) max_seeds="$value" ;;
      --candidates) candidates="$value" ;; --mask-threshold) mask_threshold="$value" ;;
      --mask-margin) mask_margin="$value" ;; --roi-margin) roi_margin="$value" ;;
      --dwi) dwi="$value" ;; --t1) t1="$value" ;; --atlas-dir) atlas_dir="$value" ;;
      --fsl-dir) fsl_dir="$value" ;; --t1-to-mni-prefix) mni_prefix="$value" ;;
      --t1-to-icbm-prefix) icbm_prefix="$value" ;; --t1-to-dwi-affine) dwi_affine="$value" ;;
    esac
    shift 2
  done
  need "${PYTHON:-python3}"
  if [[ "$mode" == setup-atlas ]]; then
    [[ -z "$input" && -z "$out" ]] || die '--setup-atlas is an installation step; omit --input and --output.'
    need curl
    fat_qc setup-atlas "$atlas_dir"
    return
  fi

  # Check the requested settings, installed resources and subject inputs.
  for value in "$threads" "$streamlines" "$max_seeds" "${candidates:-1}"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || die 'Threads and streamline/seed counts must be positive integers.'
  done
  [[ -z "$candidates" || "$candidates" -ge "$streamlines" ]] || die '--candidates must be at least --streamlines.'
  [[ "$algorithm_list" != ,* && "$algorithm_list" != *, && "$algorithm_list" != *,,* ]] || die 'Empty algorithm in list.'
  IFS=, read -r -a algorithms <<< "$algorithm_list"
  for algorithm in "${algorithms[@]}"; do
    case "$algorithm" in iFOD2|SD_STREAM|FACT|Tensor_Det|Tensor_Prob) ;; *) die "Unsupported algorithm: $algorithm" ;; esac
  done
  fat_qc parameters "$min_length" "$max_length" "$cutoff" --tensor-fa "$tensor_fa" \
    --mask-threshold "$mask_threshold" --mask-margin "$mask_margin" --roi-margin "$roi_margin"
  [[ -d "$input" ]] || die 'Set --input to the subject MRI directory.'
  input="$(cd "$input" && pwd)"
  out="${out:-$input/fat_output}"
  [[ "$mode" == check || ! -e "$out" ]] || die "Output already exists: $out. Choose a new --output directory."
  local fod="$input/wm.nii.gz" peaks="$input/peaks.nii.gz" tensor_bvalue=""
  [[ -f "$fod" ]] || fod="$input/wm.mif"
  t1="${t1:-$input/t1_brain.nii.gz}"
  dwi="${dwi:-$input/dwi_den_unr_pre_unbia.mif}"
  for value in mrinfo mrconvert tckgen antsRegistrationSyNQuick.sh antsRegistration antsApplyTransforms; do need "$value"; done
  fat_qc inputs --fod "$fod"
  fat_qc prerequisites --atlas-dir "$atlas_dir" --fsl-dir "$fsl_dir" --t1 "$t1"
  for algorithm in "${algorithms[@]}"; do
    if [[ "$algorithm" == FACT ]]; then
      need sh2peaks
      [[ ! -f "$peaks" ]] || fat_qc inputs --fod "$fod" --peaks "$peaks"
    elif [[ "$algorithm" == Tensor_* && -z "$tensor_bvalue" ]]; then
      need dwiextract
      tensor_bvalue="$(fat_qc tensor-shell "$dwi" "$fod")"
    fi
  done
  [[ "$mode" != check ]] || { printf 'Prerequisites and inputs OK.\n'; return; }
  if [[ "$mode" != dry-run ]]; then mkdir -p "$out/work"; fi
  export OMP_NUM_THREADS="$threads" ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$threads" MKL_NUM_THREADS="$threads"
  run fat_qc settings "$out/run.json" "input=$input" "t1=$t1" "dwi=$dwi" "atlas_dir=$atlas_dir" \
    "algorithms=$algorithm_list" "streamlines=$streamlines" "cutoff=$cutoff" "tensor_fa=$tensor_fa" \
    "min_length_mm=$min_length" "max_length_mm=$max_length" "threads=$threads" "max_seeds=$max_seeds" \
    "candidates=${candidates:-auto}" "mask_threshold=$mask_threshold" "mask_margin_mm=$mask_margin" "roi_margin_mm=$roi_margin"

  # Register the probability maps and cortical labels into the diffusion grid.
  atlas_args=(--threads "$threads" --atlas-dir "$atlas_dir")
  [[ -z "$mni_prefix" ]] || atlas_args+=(--mni-prefix "$mni_prefix")
  [[ -z "$icbm_prefix" ]] || atlas_args+=(--icbm-prefix "$icbm_prefix")
  [[ -z "$dwi_affine" ]] || atlas_args+=(--dwi-affine "$dwi_affine")
  run mrconvert "$fod" "$out/work/dwi_reference.nii.gz" -coord 3 0 -nthreads "$threads"
  run fat_qc atlas-to-subject --t1 "$t1" --reference "$out/work/dwi_reference.nii.gz" \
    --fsl-dir "$fsl_dir" --out "$out/work/atlas" "${atlas_args[@]}"
  local name
  for name in FAT_left FAT_right; do
    run fat_qc probability-bundle "$out/work/atlas/${name}_probability.nii.gz" \
      "$out/bundle_segmentations_original/$name.nii.gz" "$out/bundle_segmentations/$name.nii.gz" \
      --threshold "$mask_threshold" --margin "$mask_margin"
    run fat_qc endings "$out/work/atlas/endings_native.nii.gz" "$out/bundle_segmentations/$name.nii.gz" \
      "${name#FAT_}" "$out" --radius "$roi_margin"
  done

  # Prepare the input for each selected tracking algorithm.
  if [[ ",$algorithm_list," == *,FACT,* ]]; then
    if [[ ! -f "$peaks" ]]; then
      peaks="$out/work/peaks_raw.nii.gz"
      run sh2peaks "$fod" "$peaks" -num 3 -nthreads "$threads"
    fi
    run fat_qc prepare-peaks "$peaks" "$out/work/peaks.nii.gz"
    peaks="$out/work/peaks.nii.gz"
  fi
  if [[ -n "$tensor_bvalue" ]]; then
    run dwiextract "$dwi" "$out/work/tensor_dwi.mif" -shells "0,$tensor_bvalue" -nthreads "$threads"
  fi

  # Track complete connections and retain the requested number inside the mask.
  local source tracking_cutoff candidate_count bundle begin end tracks candidate_file
  for algorithm in "${algorithms[@]}"; do
    source="$fod"; tracking_cutoff="$cutoff"; candidate_count="$((streamlines * 2))"
    [[ "$algorithm" != FACT ]] || source="$peaks"
    if [[ "$algorithm" == Tensor_* ]]; then
      source="$out/work/tensor_dwi.mif"; tracking_cutoff="$tensor_fa"; candidate_count="$((streamlines * 4))"
    fi
    candidate_count="${candidates:-$candidate_count}"
    run mkdir -p "$out/${algorithm}_trackings"
    for name in FAT_left FAT_right; do
      bundle="$out/bundle_segmentations/$name.nii.gz"
      begin="$out/endings_segmentations/${name}_b.nii.gz"
      end="$out/endings_segmentations/${name}_e.nii.gz"
      tracks="$out/${algorithm}_trackings/$name.tck"
      candidate_file="$out/work/${name}_${algorithm}_candidates.tck"
      run tckgen "$source" "$candidate_file" -algorithm "$algorithm" \
        -seed_image "$out/seed_masks/${name}_b.nii.gz" -include "$begin" -include "$end" -mask "$bundle" \
        -select "$candidate_count" -seeds "$max_seeds" -minlength "$min_length" -maxlength "$max_length" \
        -cutoff "$tracking_cutoff" -downsample 1 -nthreads "$threads"
      run fat_qc filter-tracks "$candidate_file" "$bundle" "$tracks" "$streamlines" --endings "$begin" "$end"
      run fat_qc tracks "$tracks" "$streamlines" --mask "$bundle" --endings "$begin" "$end"
    done
  done
  run fat_qc summary "$out"
  run touch "$out/SUCCESS"
}

# Embedded image preparation and streamline checks.
fat_qc() {
  "${PYTHON:-python3}" - "$@" <<'FAT_QC_PY'
"""FAT atlas preparation, bounded mask processing and whole-streamline checks."""

import argparse
import csv
import hashlib
import json
import math
from pathlib import Path
import shlex
import subprocess
import sys
import xml.etree.ElementTree as ET
from zipfile import ZipFile

import nibabel as nib
import numpy as np
from scipy import ndimage as ndi


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


def image_spacing(img: nib.Nifti1Image) -> np.ndarray:
    axes = img.affine[:3, :3]
    spacing = np.linalg.norm(axes, axis=0)
    directions = axes / spacing
    if not np.allclose(directions.T @ directions, np.eye(3), atol=1e-4):
        raise ValueError("Physical dilation requires an orthogonal image grid; resample a sheared grid first.")
    return spacing


def dilate_mm(mask: np.ndarray, spacing: np.ndarray, radius: float) -> np.ndarray:
    if not math.isfinite(radius) or radius < 0:
        raise ValueError("Dilation radius must be finite and nonnegative.")
    if not mask.any():
        raise ValueError("Cannot dilate an empty region.")
    return ndi.distance_transform_edt(~mask, sampling=spacing) <= radius + 1e-5


def prepare_bundle(source: Path, destination: Path, margin: float = 1.5,
                   smoothing: float = 1.0) -> None:
    """Bounded dilation, light binary-mask smoothing, and bounded cavity filling."""
    if destination.exists():
        raise ValueError(f"Output already exists: {destination}")
    if not math.isfinite(smoothing) or smoothing < 0:
        raise ValueError("Mask smoothing must be finite and nonnegative.")
    mask, _ = mask_data(source)
    img = load_nifti(source)
    spacing = image_spacing(img)
    bound = dilate_mm(mask, spacing, margin)
    processed = bound.copy()
    if smoothing > 0:
        processed = ndi.gaussian_filter(processed.astype(float), smoothing / spacing) >= 0.5
    # Preserve all original voxels; never add beyond the explicit distance bound.
    processed = ndi.binary_fill_holes(processed | mask) & bound
    if ndi.label(processed)[1] != 1:
        raise ValueError("Processed bundle is not face-connected; inspect the segmentation before tracking.")
    nib.save(nib.Nifti1Image(processed.astype(np.uint8), img.affine), destination)
    print(f"{destination.name}: {int(mask.sum())} -> {int(processed.sum())} voxels; "
          f"margin {margin:g} mm, smoothing sigma {smoothing:g} mm; original preserved.")


def make_atlas_labels(atlas: Path, xml: Path, destination: Path) -> None:
    """Harvard-Oxford IFG pars opercularis/triangularis and SFG/SMA, per side."""
    if destination.exists():
        raise ValueError(f"Output already exists: {destination}")
    labels = {node.text: int(node.attrib['index']) + 1
              for node in ET.parse(xml).findall('./data/label')}
    img = load_nifti(atlas)
    data = np.asanyarray(img.dataobj)
    if data.ndim != 3 or not np.isfinite(data).all():
        raise ValueError("Expected the 3D Harvard-Oxford max-probability label atlas.")
    result = np.zeros(data.shape, dtype=np.uint8)
    try:
        ifg = [labels['Inferior Frontal Gyrus, pars opercularis'],
               labels['Inferior Frontal Gyrus, pars triangularis']]
        sfg = [labels['Superior Frontal Gyrus'],
               labels['Juxtapositional Lobule Cortex (formerly Supplementary Motor Cortex)']]
    except KeyError as error:
        raise ValueError("Harvard-Oxford XML is missing the required IFG/SFG/SMA labels.") from error
    for index, values in ((1, ifg), (2, sfg)):
        voxels = np.argwhere(np.isin(data, values))
        world = nib.affines.apply_affine(img.affine, voxels)
        for sign, offset in ((-1, 0), (1, 2)):
            selected = voxels[sign * world[:, 0] > 0]
            result[tuple(selected.T)] = offset + index
    if set(np.unique(result)) != {0, 1, 2, 3, 4}:
        raise ValueError("Atlas extraction produced an empty cortical region.")
    nib.save(nib.Nifti1Image(result, img.affine), destination)


def checked_archive(path: Path, url: str, expected: str) -> None:
    """Download a pinned archive once; reject corrupt or changed upstream files."""
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix('.part')
        subprocess.run(['curl', '-L', '--fail', '--retry', '2', '-o', str(temporary), url], check=True)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != expected:
            raise ValueError(f"Download checksum mismatch: {url}")
        temporary.replace(path)
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise ValueError(f"Atlas cache checksum mismatch: {path}")


def setup_atlas(folder: Path) -> Path:
    """HCP1065 probabilities and the matching ICBM2009a asymmetrical T1."""
    probability = folder / 'hcp1065_probability.zip'
    template = folder / 'icbm2009a.zip'
    checked_archive(probability,
                    'https://github.com/data-others/atlas/releases/download/hcp1065/hcp1065_prob_coverage_nifti.zip',
                    '4577abce53e05c732a0d52c88f4ee2d63488bb685f664faad2ea44aa90be8e8b')
    checked_archive(template,
                    'https://www.bic.mni.mcgill.ca/~vfonov/icbm/2009/mni_icbm152_nlin_asym_09a_nifti.zip',
                    '188e1706b0ed74a0d1b3a52ad1a2b198814815f70a65f3ded091b7ceb6296a44')
    # Extract only known members to fixed destinations, never archive-supplied paths.
    with ZipFile(probability) as archive:
        for side in ('L', 'R'):
            name = f'Frontal_Aslant_Tract_{side}.nii.gz'
            (folder / name).write_bytes(archive.read('prob/' + name))
    with ZipFile(template) as archive:
        for suffix in ('', '_mask'):
            name = f'mni_icbm152_t1_tal_nlin_asym_09a{suffix}.nii'
            (folder / name).write_bytes(archive.read('mni_icbm152_nlin_asym_09a/' + name))
        (folder / 'ICBM_COPYING.txt').write_bytes(archive.read('COPYING'))
    t1 = load_nifti(folder / 'mni_icbm152_t1_tal_nlin_asym_09a.nii')
    mask = load_nifti(folder / 'mni_icbm152_t1_tal_nlin_asym_09a_mask.nii')
    brain = folder / 'ICBM2009a_T1_brain.nii.gz'
    nib.save(nib.Nifti1Image((t1.get_fdata() * (mask.get_fdata() > 0)).astype(np.float32),
                           t1.affine), brain)
    files = {name: hashlib.sha256((folder / name).read_bytes()).hexdigest()
             for name in ATLAS_FILES}
    (folder / 'atlas_manifest.json').write_text(json.dumps(files, indent=2) + '\n')
    print(f"Atlas installed: {folder.resolve()}")
    return brain


ATLAS_FILES = ('Frontal_Aslant_Tract_L.nii.gz', 'Frontal_Aslant_Tract_R.nii.gz',
               'ICBM2009a_T1_brain.nii.gz', 'ICBM_COPYING.txt')


def installed_atlas(folder: Path) -> Path:
    """Verify prepared resources without downloads or filesystem changes."""
    manifest = folder / 'atlas_manifest.json'
    if not manifest.is_file():
        raise ValueError(f"Atlas is not installed in {folder}. Run bash fat.sh --setup-atlas --atlas-dir {shlex.quote(str(folder))}")
    files = json.loads(manifest.read_text())
    for name in ATLAS_FILES:
        path = folder / name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != files.get(name):
            raise ValueError(f"Atlas file missing or checksum mismatch: {path}. Repeat --setup-atlas.")
    return folder / 'ICBM2009a_T1_brain.nii.gz'


def prerequisites(folder: Path, fsl: Path, t1: Path) -> None:
    installed_atlas(folder)
    for relative in ('data/atlases/HarvardOxford/HarvardOxford-cort-maxprob-thr25-1mm.nii.gz',
                     'data/atlases/HarvardOxford-Cortical.xml',
                     'data/standard/MNI152_T1_1mm_brain.nii.gz'):
        if not (fsl / relative).is_file():
            raise ValueError(f"Missing FSL file: {fsl / relative}. Set FSLDIR or --fsl-dir.")
    image = load_nifti(t1)
    if len(image.shape) != 3 or not np.isfinite(image.get_fdata()).all():
        raise ValueError('T1 must be a finite 3D brain-extracted image.')


def probability_bundle(source: Path, original: Path, destination: Path,
                       threshold: float = 0.05, margin: float = 3.0) -> None:
    """Threshold a registered probability prior, drop tiny islands, bound smoothing."""
    if original.exists() or destination.exists():
        raise ValueError('Bundle output already exists.')
    if not math.isfinite(threshold) or not 0 < threshold < 1:
        raise ValueError('Probability threshold must be between 0 and 1.')
    img = load_nifti(source)
    data = img.get_fdata()
    if data.ndim != 3 or not np.isfinite(data).all() or data.min() < 0 or data.max() > 1:
        raise ValueError('Expected finite 3D probabilities in [0, 1], not percentages.')
    raw = data >= threshold
    components, count = ndi.label(raw)
    sizes = np.bincount(components.ravel())
    sizes[0] = 0
    if count == 0:
        raise ValueError('Empty probability mask at the selected threshold.')
    mask = components == sizes.argmax()
    retained = float(mask.sum() / raw.sum())
    if retained < 0.95:
        raise ValueError('Major disconnected atlas components; inspect registration/threshold.')
    spacing = image_spacing(img)
    bound = dilate_mm(mask, spacing, margin)
    processed = ndi.gaussian_filter(bound.astype(float), 1.0 / spacing) >= 0.5
    processed = ndi.binary_fill_holes(processed | mask) & bound
    if ndi.label(processed)[1] != 1:
        raise ValueError('Processed atlas mask is not face-connected.')
    for path, array in ((original, raw), (destination, processed)):
        path.parent.mkdir(parents=True, exist_ok=True)
        nib.save(nib.Nifti1Image(array.astype(np.uint8), img.affine), path)
    report = {'source': str(source), 'threshold': threshold, 'raw_voxels': int(raw.sum()),
              'raw_components6': count, 'retained_fraction': retained,
              'removed_island_voxels': int(raw.sum() - mask.sum()),
              'tracking_voxels': int(processed.sum()), 'margin_mm': margin, 'smoothing_sigma_mm': 1.0}
    destination.with_suffix('').with_suffix('.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report), flush=True)


def atlas_to_subject(t1: Path, reference: Path, fsl_dir: Path, out: Path,
                     mni_prefix: str | None = None, dwi_affine: Path | None = None,
                     threads: int = 4, atlas_dir: Path = Path('atlases/hcp1065'),
                     icbm_prefix: str | None = None) -> None:
    """Register atlas priors through this subject's T1 into the diffusion grid."""
    if out.exists():
        raise ValueError(f"Output already exists: {out}")
    atlas = fsl_dir / "data/atlases/HarvardOxford/HarvardOxford-cort-maxprob-thr25-1mm.nii.gz"
    xml = fsl_dir / "data/atlases/HarvardOxford-Cortical.xml"
    template = fsl_dir / "data/standard/MNI152_T1_1mm_brain.nii.gz"
    for path in (t1, reference, atlas, xml, template):
        if not path.is_file():
            raise ValueError(f"Missing anatomical preparation input: {path}")
    t1_img = load_nifti(t1)
    if len(t1_img.shape) != 3 or not np.isfinite(t1_img.get_fdata()).all():
        raise ValueError("T1 must be a finite 3D brain-extracted image of this subject.")
    icbm_template = installed_atlas(atlas_dir)
    out.mkdir(parents=True)
    ref_img = load_nifti(reference)
    ref_data = np.asanyarray(ref_img.dataobj)
    if ref_data.ndim == 4:
        ref_data = ref_data[..., 0]
    if ref_data.ndim != 3:
        raise ValueError("Expected a 3D image or 4D FOD reference.")
    ref = out / "dwi_reference.nii.gz"
    nib.save(nib.Nifti1Image(ref_data.astype(np.float32), ref_img.affine), ref)
    make_atlas_labels(atlas, xml, out / "endings_MNI.nii.gz")
    commands = []

    def run(command: list[str]) -> None:
        print("+ " + shlex.join(command), flush=True)
        commands.append(command)
        subprocess.run(command, check=True)

    if mni_prefix is None:
        mni_prefix = str(out / "T1toMNI_")
        run(["antsRegistrationSyNQuick.sh", "-d", "3", "-f", str(template), "-m", str(t1),
             "-t", "s", "-n", str(threads), "-o", mni_prefix])
    mni_affine = Path(mni_prefix + "0GenericAffine.mat")
    inverse_warp = Path(mni_prefix + "1InverseWarp.nii.gz")
    if dwi_affine is None:
        dwi_prefix = str(out / "T1toDWI_")
        run(["antsRegistrationSyNQuick.sh", "-d", "3", "-f", str(ref), "-m", str(t1),
             "-t", "r", "-n", str(threads), "-o", dwi_prefix])
        dwi_affine = Path(dwi_prefix + "0GenericAffine.mat")
    for path in (mni_affine, inverse_warp, dwi_affine):
        if not path.is_file():
            raise ValueError(f"Missing subject registration transform: {path}")
    run(["antsApplyTransforms", "-d", "3", "-i", str(out / "endings_MNI.nii.gz"),
         "-r", str(ref), "-o", str(out / "endings_native.nii.gz"), "-n", "NearestNeighbor",
         "-t", str(dwi_affine), "-t", f"[{mni_affine},1]", "-t", str(inverse_warp)])
    run(["antsApplyTransforms", "-d", "3", "-i", str(t1), "-r", str(ref),
         "-o", str(out / "t1_dwi.nii.gz"), "-n", "Linear", "-t", str(dwi_affine)])
    # HCP1065 uses ICBM2009a, not the FSL MNI152 template used by Harvard-Oxford.
    if icbm_prefix is None:
        icbm_prefix = str(out / 'T1toICBM2009a_')
        run(['antsRegistrationSyNQuick.sh', '-d', '3', '-f', str(icbm_template), '-m', str(t1),
             '-t', 's', '-n', str(threads), '-o', icbm_prefix])
    icbm_affine = Path(icbm_prefix + '0GenericAffine.mat')
    icbm_inverse = Path(icbm_prefix + '1InverseWarp.nii.gz')
    for path in (icbm_affine, icbm_inverse):
        if not path.is_file():
            raise ValueError(f'Missing ICBM2009a transform: {path}')
    for side, name in (('L', 'left'), ('R', 'right')):
        run(['antsApplyTransforms', '-d', '3', '-i', str(atlas_dir / f'Frontal_Aslant_Tract_{side}.nii.gz'),
             '-r', str(ref), '-o', str(out / f'FAT_{name}_probability.nii.gz'), '-n', 'Linear',
             '-t', str(dwi_affine), '-t', f'[{icbm_affine},1]', '-t', str(icbm_inverse)])
    (out / "registration.json").write_text(json.dumps({
        "t1": str(t1), "diffusion_reference": str(reference), "atlas": str(atlas),
        "t1_to_mni_affine": str(mni_affine), "mni_to_t1_warp": str(inverse_warp),
        "t1_to_dwi_affine": str(dwi_affine), "commands": commands,
        "bundle_atlas": "HCP1065 probability coverage", "bundle_template": str(icbm_template),
        "t1_to_icbm2009a_affine": str(icbm_affine), "icbm2009a_to_t1_warp": str(icbm_inverse),
    }, indent=2) + "\n")


def anatomical_endings(atlas: Path, bundle: Path, side: str, out: Path,
                       radius: float = 3.0) -> None:
    """Keep full cortical ROIs; save their mask intersection separately for seeding."""
    same_grid(bundle, atlas)
    img = load_nifti(atlas)
    data = np.asanyarray(img.dataobj)
    if data.ndim != 3 or not np.isin(data, [0, 1, 2, 3, 4]).all():
        raise ValueError("Expected the registered four-region cortical label image.")
    mask, _ = mask_data(bundle)
    offset = {"left": 0, "right": 2}[side]
    name = f"FAT_{side}"
    paths = [out / directory / f"{name}_{suffix}.nii.gz"
             for directory in ("anatomical_rois", "endings_segmentations", "seed_masks")
             for suffix in ("b", "e")]
    if any(path.exists() for path in paths):
        raise ValueError("Anatomical end-region output already exists.")
    regions = []
    for index, suffix in enumerate(("b", "e"), start=1):
        raw = data == offset + index
        expanded = dilate_mm(raw, image_spacing(img), radius)
        effective = expanded & mask
        if not effective.any():
            raise ValueError(f"{name}_{suffix}: cortical ROI does not reach the bundle; inspect registration.")
        regions.append((raw, expanded, effective))
    if (regions[0][2] & regions[1][2]).any():
        raise ValueError("Anatomical end regions overlap inside the bundle; inspect registration/margins.")
    for suffix, arrays in zip(("b", "e"), regions):
        for directory, array in zip(("anatomical_rois", "endings_segmentations", "seed_masks"), arrays):
            path = out / directory / f"{name}_{suffix}.nii.gz"
            path.parent.mkdir(parents=True, exist_ok=True)
            nib.save(nib.Nifti1Image(array.astype(np.uint8), img.affine), path)
        print(f"{name}_{suffix}: cortex {int(arrays[0].sum())}; "
              f"with {radius:g} mm margin {int(arrays[1].sum())}; "
              f"inside tracking mask {int(arrays[2].sum())} voxels.")


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


def tensor_shell(source: Path, reference: Path) -> float:
    """Check DWI gradients and return the lowest nonzero MRtrix b-value shell."""
    same_grid(reference, source)
    shape, _ = geometry(source)
    result = subprocess.run(["mrinfo", str(source), "-dwgrad"], capture_output=True, text=True)
    if result.returncode:
        raise ValueError(f"Cannot read DWI gradients from {source}: {result.stderr.strip()}")
    gradients = np.array([[float(v) for v in line.split()]
                          for line in result.stdout.splitlines() if line.strip()])
    if (len(shape) != 4 or gradients.shape != (shape[-1], 4)
            or not np.isfinite(gradients).all() or np.any(gradients[:, 3] < 0)):
        raise ValueError("Tensor tracking requires 4D DWI with a finite embedded MRtrix gradient table.")
    if not np.any(gradients[:, 3] < 100):
        raise ValueError("Tensor tracking requires b=0 volumes.")
    result = subprocess.run(["mrinfo", str(source), "-shell_bvalues"],
                            check=True, capture_output=True, text=True)
    shells = [float(v) for v in result.stdout.split() if float(v) >= 100]
    if not shells:
        raise ValueError("Tensor tracking requires diffusion-weighted volumes.")
    shell = min(shells)
    g = gradients[np.abs(gradients[:, 3] - shell) < max(100, shell * 0.1), :3]
    design = np.column_stack((g[:, 0] ** 2, g[:, 1] ** 2, g[:, 2] ** 2,
                              g[:, 0] * g[:, 1], g[:, 0] * g[:, 2], g[:, 1] * g[:, 2]))
    if len(design) < 6 or np.linalg.matrix_rank(design) < 6:
        raise ValueError("The lowest DWI shell needs at least six independent tensor directions.")
    return shell


def summary(out: Path) -> None:
    with (out / "qc_summary.csv").open("w", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["bundle", "original_voxels", "tracking_voxels", "tracking_volume_mm3",
                         "original_components6", "tracking_components6", "original_cavity_voxels"])
        for name in ("FAT_left", "FAT_right"):
            img = load_nifti(out / "bundle_segmentations" / f"{name}.nii.gz")
            voxels = int(np.count_nonzero(np.asanyarray(img.dataobj)))
            volume = voxels * abs(np.linalg.det(img.affine[:3, :3]))
            original, _ = mask_data(out / "bundle_segmentations_original" / f"{name}.nii.gz")
            tracking = np.asanyarray(img.dataobj) > 0
            writer.writerow([name, int(original.sum()), voxels, f"{volume:.3f}",
                             ndi.label(original)[1], ndi.label(tracking)[1],
                             int((ndi.binary_fill_holes(original) & ~original).sum())])
    with (out / "roi_qc.csv").open("w", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["region", "volume_mm3", "voxels", "voxels_inside_tracking_mask"])
        for path in sorted((out / "endings_segmentations").glob("*.nii.gz")):
            img = load_nifti(path)
            region = np.asanyarray(img.dataobj) > 0
            name = path.name.rsplit("_", 1)[0]
            bundle, _ = mask_data(out / "bundle_segmentations" / f"{name}.nii.gz")
            writer.writerow([path.name, f"{region.sum() * abs(np.linalg.det(img.affine[:3, :3])):.3f}",
                             int(region.sum()), int((region & bundle).sum())])
    (out / "METHOD.txt").write_text(
        "HCP1065 FAT probabilities registered through the subject T1 into diffusion space.\n"
        "Cortical targets: Harvard-Oxford IFG pars opercularis/triangularis and SFG/SMA.\n"
        "Tracking and final polyline checks use bundle_segmentations.\n"
        "Each retained streamline connects opposite regions in endings_segmentations.\n"
        "Effective settings: run.json; executed commands: commands.log.\n"
        "Atlas: Yeh (2022), doi:10.1038/s41467-022-32595-4, CC BY-SA 4.0.\n"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("setup-atlas").add_argument("folder", type=Path)
    prereq = sub.add_parser("prerequisites")
    for name in ("atlas-dir", "fsl-dir", "t1"):
        prereq.add_argument(f"--{name}", type=Path, required=True)
    settings = sub.add_parser("settings")
    settings.add_argument("destination", type=Path)
    settings.add_argument("values", nargs="+")
    parameters = sub.add_parser("parameters")
    parameters.add_argument("minimum", type=float)
    parameters.add_argument("maximum", type=float)
    parameters.add_argument("cutoff", type=float)
    parameters.add_argument("--tensor-fa", type=float, default=0.1)
    parameters.add_argument("--mask-threshold", type=float, default=0.05)
    parameters.add_argument("--mask-margin", type=float, default=3)
    parameters.add_argument("--roi-margin", type=float, default=3)
    inputs = sub.add_parser("inputs")
    inputs.add_argument("--peaks", type=Path)
    inputs.add_argument("--fod", type=Path)
    inputs.add_argument("--scalar", type=Path, action="append", default=[])
    tensor = sub.add_parser("tensor-shell")
    tensor.add_argument("source", type=Path)
    tensor.add_argument("reference", type=Path)
    export = sub.add_parser("export")
    for name in ("source", "reference", "destination"):
        export.add_argument(name, type=Path)
    prepare = sub.add_parser("prepare-peaks")
    prepare.add_argument("source", type=Path)
    prepare.add_argument("destination", type=Path)
    bundle = sub.add_parser("prepare-bundle")
    bundle.add_argument("source", type=Path)
    bundle.add_argument("destination", type=Path)
    bundle.add_argument("--margin", type=float, default=1.5)
    bundle.add_argument("--smoothing", type=float, default=1.0)
    probability = sub.add_parser('probability-bundle')
    for name in ('source', 'original', 'destination'):
        probability.add_argument(name, type=Path)
    probability.add_argument('--threshold', type=float, default=0.05)
    probability.add_argument('--margin', type=float, default=3.0)
    atlas = sub.add_parser("atlas-to-subject")
    for name in ("t1", "reference", "fsl-dir", "out"):
        atlas.add_argument(f"--{name}", type=Path, required=True)
    atlas.add_argument("--mni-prefix")
    atlas.add_argument("--dwi-affine", type=Path)
    atlas.add_argument("--threads", type=int, default=4)
    atlas.add_argument('--atlas-dir', type=Path, default=Path('atlases/hcp1065'))
    atlas.add_argument('--icbm-prefix')
    endings = sub.add_parser("endings")
    endings.add_argument("atlas", type=Path)
    endings.add_argument("bundle", type=Path)
    endings.add_argument("side", choices=("left", "right"))
    endings.add_argument("out", type=Path)
    endings.add_argument("--radius", type=float, default=3.0)
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
    if args.command == "setup-atlas":
        setup_atlas(args.folder)
    elif args.command == "prerequisites":
        prerequisites(args.atlas_dir, args.fsl_dir, args.t1)
    elif args.command == "settings":
        args.destination.write_text(json.dumps(dict(v.split("=", 1) for v in args.values), indent=2) + "\n")
    elif args.command == "parameters":
        if not all(math.isfinite(x) for x in (args.minimum, args.maximum, args.cutoff)):
            raise ValueError("Tracking parameters must be finite.")
        if not 0 < args.minimum < args.maximum or args.cutoff <= 0:
            raise ValueError("Require 0 < --min-length < --max-length and --cutoff > 0.")
        if not math.isfinite(args.tensor_fa) or not 0 < args.tensor_fa < 1:
            raise ValueError("--tensor-fa must be between 0 and 1.")
        if not math.isfinite(args.mask_threshold) or not 0 < args.mask_threshold < 1:
            raise ValueError("--mask-threshold must be between 0 and 1.")
        for value in (args.mask_margin, args.roi_margin):
            if not math.isfinite(value) or value < 0:
                raise ValueError("Mask and ROI margins must be finite and nonnegative.")
    elif args.command == "inputs":
        validate_inputs(args.peaks, args.fod, args.scalar)
    elif args.command == "tensor-shell":
        print(f"{tensor_shell(args.source, args.reference):.6g}")
    elif args.command == "export":
        export_mask(args.source, args.reference, args.destination)
    elif args.command == "prepare-peaks":
        img = load_nifti(args.source)
        data = clean_peaks(np.asanyarray(img.dataobj))
        nib.save(nib.Nifti1Image(data.astype(np.float32), img.affine), args.destination)
    elif args.command == "prepare-bundle":
        prepare_bundle(args.source, args.destination, args.margin, args.smoothing)
    elif args.command == 'probability-bundle':
        probability_bundle(args.source, args.original, args.destination, args.threshold, args.margin)
    elif args.command == "atlas-to-subject":
        atlas_to_subject(args.t1, args.reference, args.fsl_dir, args.out,
                         args.mni_prefix, args.dwi_affine, args.threads, args.atlas_dir, args.icbm_prefix)
    elif args.command == "endings":
        anatomical_endings(args.atlas, args.bundle, args.side, args.out, args.radius)
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_fat_pipeline "$@"
fi
