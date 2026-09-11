#!/usr/bin/env bash
# Workflow author: Lucius Fekonja
# Atlas: Yeh FC (2022), https://doi.org/10.1038/s41467-022-32595-4; CC BY-SA 4.0.
# HCP1065 FAT atlas registration; optional MRtrix tracking.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() {
  cat <<'EOF'
Usage: tractseg_xtract_fat.sh [segment|run|check|dry-run] [DWI_DIR ...]

Default: segment the bundled mri/ example. Multiple DWI_DIRs enable batch mode.
segment  Register HCP1065 probabilities and cortex; prepare FAT_left/right masks.
run      Track connections between two registered cortical end regions, inside the FAT mask.
check    Validate dependencies, input dimensions and image grids; no inference.
dry-run  Validate inputs and print commands; no output directory is created.

Input names: peaks.nii.gz and/or wm.nii.gz / wm.mif.
Optional: mask.nii.gz / mask.mif; fa.nii.gz / fa.mif.
Environment:
  OUTPUT_DIR       Output override (one subject only; must not exist).
  PYTHON=python3   Python with numpy, nibabel, scipy.
  NTHREADS=4       CPUs for ANTs/MRtrix.
  ALGORITHMS="iFOD2 SD_STREAM FACT"  Tracking algorithms for run/dry-run.
  N_STREAMLINES=2000  MAX_SEEDS=2000000
  Twice N_STREAMLINES candidates are generated; retain exactly N_STREAMLINES
  whole streamlines inside the mask, with endpoints in opposite end regions.
  MIN_LENGTH=20   MAX_LENGTH=150   CUTOFF=0.05
  DENSITY=0       Also predict XTRACT density maps (1 to enable).
  COMPUTE_FA=0    Fit FA from dwi_den_unr_pre_unbia.mif if absent (1 to enable).
  T1              Brain-extracted T1 (default: DWI_DIR/t1_brain.nii.gz).
  FSLDIR          FSL installation containing Harvard-Oxford and MNI T1 template.
  ATLAS_DIR       HCP1065/ICBM2009a download cache (default: SCRIPT_DIR/atlases/hcp1065).
  T1_TO_ICBM_PREFIX Optional T1-to-ICBM2009a prefix, separate from FSL MNI152.
  T1_TO_MNI_PREFIX Optional existing ANTs T1-to-MNI prefix (affine + inverse warp).
  T1_TO_DWI_AFFINE Optional existing ANTs rigid T1-to-DWI affine.
  ROI_DIR         Optional native-space fa_l/{seed,target,exclude}.nii.gz and
                  fa_r/{seed,target,exclude}.nii.gz; all six files required.

Default cortex: Harvard-Oxford IFG pars opercularis/triangularis and SFG plus SMA,
with a 3 mm margin. HCP1065 probabilities use a 0.05 threshold, largest component
(at least 95% of threshold voxels), bounded 3 mm margin and 1 mm smoothing.
Raw threshold masks are retained in bundle_segmentations_original.
No training or TractSeg inference is needed unless optional DENSITY=1 is used.
See README.md before interpreting patient results.
EOF
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command missing: $1"; }
run() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  if [[ "$MODE" != dry-run ]]; then "$@"; fi
}
choose_file() {
  local candidate
  for candidate in "$@"; do
    if [[ -f "$candidate" ]]; then printf '%s\n' "$candidate"; return; fi
  done
  return 0
}

MODE="${1:-segment}"
if [[ $# -gt 0 ]]; then shift; fi
case "$MODE" in
  -h|--help|help) usage; exit 0 ;;
  segment|run|check|dry-run) ;;
  *) usage >&2; die "Unknown mode: $MODE" ;;
esac
if [[ $# -eq 0 ]]; then set -- "$SCRIPT_DIR/mri"; fi
[[ $# -eq 1 || -z "${OUTPUT_DIR:-}" ]] || die 'OUTPUT_DIR is only allowed for one input directory.'

PYTHON="${PYTHON:-python3}"
NTHREADS="${NTHREADS:-4}"
N_STREAMLINES="${N_STREAMLINES:-2000}"
MAX_SEEDS="${MAX_SEEDS:-2000000}"
MIN_LENGTH="${MIN_LENGTH:-20}"
MAX_LENGTH="${MAX_LENGTH:-150}"
CUTOFF="${CUTOFF:-0.05}"
DENSITY="${DENSITY:-0}"
COMPUTE_FA="${COMPUTE_FA:-0}"
read -r -a algorithms <<< "${ALGORITHMS:-iFOD2 SD_STREAM FACT}"
for value in "$NTHREADS" "$N_STREAMLINES" "$MAX_SEEDS"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die 'Threads and streamline/seed counts must be positive integers.'
done
[[ "$DENSITY" =~ ^[01]$ && "$COMPUTE_FA" =~ ^[01]$ ]] || die 'DENSITY and COMPUTE_FA must be 0 or 1.'
for algorithm in "${algorithms[@]}"; do
  case "$algorithm" in iFOD2|SD_STREAM|FACT) ;; *) die "Unsupported algorithm: $algorithm" ;; esac
done
[[ ${#algorithms[@]} -gt 0 ]] || die 'ALGORITHMS must not be empty.'
for command in "$PYTHON" mrinfo mrconvert sh2peaks; do need "$command"; done
[[ "$DENSITY" == 0 ]] || need TractSeg
"$PYTHON" "$SCRIPT_DIR/scripts/fat_qc.py" parameters "$MIN_LENGTH" "$MAX_LENGTH" "$CUTOFF"

for input in "$@"; do
  [[ -d "$input" ]] || die "Input directory missing: $input"
  input="$(cd "$input" && pwd)"
  out="${OUTPUT_DIR:-$input/tractseg_xtract_fat_output}"
  fod="$(choose_file "$input/wm.nii.gz" "$input/wm.mif")"
  peaks="$(choose_file "$input/peaks.nii.gz")"
  mask="$(choose_file "$input/mask.nii.gz" "$input/mask.mif")"
  scalar="$(choose_file "$input/fa.nii.gz" "$input/fa.mif")"
  [[ -n "$fod" ]] || die "Atlas registration requires wm.nii.gz/wm.mif in $input"
  [[ -f "${T1:-$input/t1_brain.nii.gz}" ]] || die "Atlas registration requires a brain-extracted T1."
  for command in antsRegistrationSyNQuick.sh antsApplyTransforms curl; do need "$command"; done
  if [[ "$MODE" == run || "$MODE" == dry-run ]]; then
    for command in tckgen tckinfo tckmap; do need "$command"; done
    for algorithm in "${algorithms[@]}"; do
      [[ "$algorithm" == FACT || -n "$fod" ]] || die "$algorithm requires WM FODs, not peaks."
    done
    if [[ -z "${ROI_DIR:-}" ]]; then
      [[ -n "$fod" ]] || die 'Atlas registration requires WM FODs as its diffusion reference.'
      [[ -f "${T1:-$input/t1_brain.nii.gz}" ]] || die 'Atlas end regions require a brain-extracted T1.'
      for command in antsRegistrationSyNQuick.sh antsApplyTransforms; do need "$command"; done
    fi
    if [[ -z "$scalar" && "$COMPUTE_FA" == 1 ]]; then
      [[ -f "$input/dwi_den_unr_pre_unbia.mif" && -n "$mask" ]] || die 'Computing FA requires DWI and brain mask.'
      need dwi2tensor; need tensor2metric
    fi
    if [[ -n "$scalar" || "$COMPUTE_FA" == 1 ]]; then need tcksample; fi
  fi
  qc_args=(inputs)
  [[ -z "$peaks" ]] || qc_args+=(--peaks "$peaks")
  [[ -z "$fod" ]] || qc_args+=(--fod "$fod")
  [[ -z "$mask" ]] || qc_args+=(--scalar "$mask")
  [[ -z "$scalar" ]] || qc_args+=(--scalar "$scalar")
  if [[ -n "${ROI_DIR:-}" ]]; then
    for tract in fa_l fa_r; do
      for roi in seed target exclude; do qc_args+=(--scalar "$ROI_DIR/$tract/$roi.nii.gz"); done
    done
  fi
  "$PYTHON" "$SCRIPT_DIR/scripts/fat_qc.py" "${qc_args[@]}"
  [[ "$MODE" != check ]] || continue
  [[ ! -e "$out" ]] || die "Output already exists: $out. Choose a new OUTPUT_DIR to avoid mixing runs."
  run mkdir -p "$out/work" "$out/bundle_segmentations_original" "$out/bundle_segmentations" "$out/endings_segmentations" "$out/tractometry"
  if [[ "$MODE" != dry-run ]]; then
    exec 3>&1 4>&2
    exec > >(tee "$out/pipeline.log") 2>&1
    export TRACTSEG_WEIGHTS_DIR="${TRACTSEG_WEIGHTS_DIR:-$SCRIPT_DIR/weights}"
    export MPLCONFIGDIR="${MPLCONFIGDIR:-$out/work/matplotlib}"
    export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$out/work/cache}"
    export OMP_NUM_THREADS="$NTHREADS"
    export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$NTHREADS"
    export MKL_NUM_THREADS="$NTHREADS"
    mkdir -p "$TRACTSEG_WEIGHTS_DIR" "$MPLCONFIGDIR" "$XDG_CACHE_HOME"
    printf 'Input: %s\nMode: %s\n' "$input" "$MODE"
    mrinfo -version
  fi
  if [[ -z "$peaks" ]]; then
    peaks="$out/work/peaks_raw.nii.gz"
    run sh2peaks "$fod" "$peaks" -num 3 -nthreads "$NTHREADS"
  fi
  run "$PYTHON" "$SCRIPT_DIR/scripts/fat_qc.py" prepare-peaks "$peaks" "$out/work/peaks.nii.gz"
  peaks="$out/work/peaks.nii.gz"
  atlas_args=(--threads "$NTHREADS" --atlas-dir "${ATLAS_DIR:-$SCRIPT_DIR/atlases/hcp1065}")
  [[ -z "${T1_TO_MNI_PREFIX:-}" ]] || atlas_args+=(--mni-prefix "$T1_TO_MNI_PREFIX")
  [[ -z "${T1_TO_ICBM_PREFIX:-}" ]] || atlas_args+=(--icbm-prefix "$T1_TO_ICBM_PREFIX")
  [[ -z "${T1_TO_DWI_AFFINE:-}" ]] || atlas_args+=(--dwi-affine "$T1_TO_DWI_AFFINE")
  run mrconvert "$fod" "$out/work/dwi_reference.nii.gz" -coord 3 0 -nthreads "$NTHREADS"
  run "$PYTHON" "$SCRIPT_DIR/scripts/fat_qc.py" atlas-to-subject \
    --t1 "${T1:-$input/t1_brain.nii.gz}" --reference "$out/work/dwi_reference.nii.gz" --fsl-dir "${FSLDIR:?Set FSLDIR for Harvard-Oxford.}" \
    --out "$out/work/atlas" "${atlas_args[@]}"
  for name in FAT_left FAT_right; do
    run "$PYTHON" "$SCRIPT_DIR/scripts/fat_qc.py" probability-bundle \
      "$out/work/atlas/${name}_probability.nii.gz" \
      "$out/bundle_segmentations_original/$name.nii.gz" "$out/bundle_segmentations/$name.nii.gz"
  done
  if [[ "$DENSITY" == 1 ]]; then
    run TractSeg -i "$peaks" -o "$out/work/xtract_model" --tract_definition xtract \
      --output_type dm_regression --nr_cpus "$NTHREADS"
    run mkdir -p "$out/density_maps"
    run cp "$out/work/xtract_model/dm_regression/fa_l.nii.gz" "$out/density_maps/FAT_left.nii.gz"
    run cp "$out/work/xtract_model/dm_regression/fa_r.nii.gz" "$out/density_maps/FAT_right.nii.gz"
  fi
  if [[ "$MODE" == run || "$MODE" == dry-run ]]; then
    for pair in 'fa_l FAT_left' 'fa_r FAT_right'; do
      read -r tract name <<< "$pair"
      if [[ -n "${ROI_DIR:-}" ]]; then
        run cp "$ROI_DIR/$tract/seed.nii.gz" "$out/endings_segmentations/${name}_b.nii.gz"
        run cp "$ROI_DIR/$tract/target.nii.gz" "$out/endings_segmentations/${name}_e.nii.gz"
      else
        run "$PYTHON" "$SCRIPT_DIR/scripts/fat_qc.py" endings "$out/work/atlas/endings_native.nii.gz" \
          "$out/bundle_segmentations/$name.nii.gz" "${name#FAT_}" "$out"
      fi
    done
    if [[ -z "$scalar" && "$COMPUTE_FA" == 1 ]]; then
      run dwi2tensor "$input/dwi_den_unr_pre_unbia.mif" "$out/work/tensors.mif" -mask "$mask" -nthreads "$NTHREADS"
      run tensor2metric "$out/work/tensors.mif" -fa "$out/work/fa.nii.gz" -nthreads "$NTHREADS"
      scalar="$out/work/fa.nii.gz"
    fi
    for algorithm in "${algorithms[@]}"; do
      run mkdir -p "$out/${algorithm}_trackings" "$out/track_density/$algorithm"
      for pair in 'fa_l FAT_left' 'fa_r FAT_right'; do
        read -r tract name <<< "$pair"
        bundle="$out/bundle_segmentations/$name.nii.gz"
        tracks="$out/${algorithm}_trackings/$name.tck"
        candidates="$out/work/${name}_${algorithm}_candidates.tck"
        begin="$out/endings_segmentations/${name}_b.nii.gz"
        end="$out/endings_segmentations/${name}_e.nii.gz"
        source="$fod"
        [[ "$algorithm" != FACT ]] || source="$peaks"
        seed="$out/seed_masks/${name}_b.nii.gz"
        [[ -z "${ROI_DIR:-}" ]] || seed="$begin"
        roi_args=(-seed_image "$seed" -include "$begin" -include "$end")
        if [[ -n "${ROI_DIR:-}" ]]; then
          roi_args+=(-exclude "$ROI_DIR/$tract/exclude.nii.gz")
        fi
        # Multiple MRtrix -mask options are a UNION, not an intersection.
        # Use only the saved processed bundle mask, also used by the final filter.
        run tckgen "$source" "$candidates" -algorithm "$algorithm" "${roi_args[@]}" -mask "$bundle" \
          -select "$((N_STREAMLINES * 2))" -seeds "$MAX_SEEDS" -minlength "$MIN_LENGTH" -downsample 1 \
          -maxlength "$MAX_LENGTH" -cutoff "$CUTOFF" -nthreads "$NTHREADS"
        run "$PYTHON" "$SCRIPT_DIR/scripts/fat_qc.py" filter-tracks "$candidates" "$bundle" "$tracks" "$N_STREAMLINES" --endings "$begin" "$end"
        run "$PYTHON" "$SCRIPT_DIR/scripts/fat_qc.py" tracks "$tracks" "$N_STREAMLINES" --mask "$bundle" --endings "$begin" "$end"
        run tckmap "$tracks" "$out/track_density/$algorithm/$name.nii.gz" -template "$bundle" -upsample 1 -nthreads "$NTHREADS"
        if [[ -n "$scalar" ]]; then
          run tcksample "$tracks" "$scalar" "$out/tractometry/${name}_${algorithm}_mean_FA.csv" \
            -stat_tck mean -nthreads "$NTHREADS"
        fi
      done
    done
  fi
  run "$PYTHON" "$SCRIPT_DIR/scripts/fat_qc.py" summary "$out"
  run touch "$out/SUCCESS"
  if [[ "$MODE" != dry-run ]]; then exec 1>&3 2>&4 3>&- 4>&-; fi
done
