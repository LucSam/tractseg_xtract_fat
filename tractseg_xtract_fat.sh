#!/usr/bin/env bash
# Workflow author: Lucius Fekonja
# FAT segmentation using TractSeg's XTRACT model; optional MRtrix tracking.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() {
  cat <<'EOF'
Usage: tractseg_xtract_fat.sh [segment|run|check|dry-run] [DWI_DIR ...]

Default: segment the bundled mri/ example. Multiple DWI_DIRs enable batch mode.
segment  TractSeg --tract_definition xtract; export FAT_left/right masks.
run      Track connections between two mask-derived end regions, inside the FAT mask.
check    Validate dependencies, input dimensions and image grids; no inference.
dry-run  Validate inputs and print commands; no output directory is created.

Input names: peaks.nii.gz and/or wm.nii.gz / wm.mif.
Optional: mask.nii.gz / mask.mif; fa.nii.gz / fa.mif.
Environment:
  OUTPUT_DIR       Output override (one subject only; must not exist).
  PYTHON=python3   Python with numpy and nibabel.
  NTHREADS=4       CPUs for TractSeg/MRtrix.
  ALGORITHMS="iFOD2 SD_STREAM FACT"  Tracking algorithms for run/dry-run.
  N_STREAMLINES=2000  MAX_SEEDS=2000000
  Twice N_STREAMLINES candidates are generated; retain exactly N_STREAMLINES
  whole streamlines inside the mask, with endpoints in opposite end regions.
  MIN_LENGTH=20   MAX_LENGTH=150   CUTOFF=0.1
  DENSITY=0       Also predict XTRACT density maps (1 to enable).
  COMPUTE_FA=0    Fit FA from dwi_den_unr_pre_unbia.mif if absent (1 to enable).
  ROI_DIR         Optional native-space fa_l/{seed,target,exclude}.nii.gz and
                  fa_r/{seed,target,exclude}.nii.gz; all six files required.

No FAT TOM/endings model exists. Default end regions are geometric terminal caps
of each individual's predicted mask, not learned anatomical IFG/SMA labels.
No training is performed; the pretrained TractSeg model predicts subject masks.
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
CUTOFF="${CUTOFF:-0.1}"
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
for command in "$PYTHON" TractSeg mrinfo mrconvert sh2peaks; do need "$command"; done
"$PYTHON" "$SCRIPT_DIR/scripts/fat_qc.py" parameters "$MIN_LENGTH" "$MAX_LENGTH" "$CUTOFF"

for input in "$@"; do
  [[ -d "$input" ]] || die "Input directory missing: $input"
  input="$(cd "$input" && pwd)"
  out="${OUTPUT_DIR:-$input/tractseg_xtract_fat_output}"
  fod="$(choose_file "$input/wm.nii.gz" "$input/wm.mif")"
  peaks="$(choose_file "$input/peaks.nii.gz")"
  mask="$(choose_file "$input/mask.nii.gz" "$input/mask.mif")"
  scalar="$(choose_file "$input/fa.nii.gz" "$input/fa.mif")"
  [[ -n "$peaks" || -n "$fod" ]] || die "Neither peaks.nii.gz nor wm.nii.gz/wm.mif found in $input"
  if [[ "$MODE" == run || "$MODE" == dry-run ]]; then
    for command in tckgen tckinfo tckmap; do need "$command"; done
    for algorithm in "${algorithms[@]}"; do
      [[ "$algorithm" == FACT || -n "$fod" ]] || die "$algorithm requires WM FODs, not peaks."
    done
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
  run mkdir -p "$out/work" "$out/bundle_segmentations" "$out/endings_segmentations" "$out/tractometry"
  if [[ "$MODE" != dry-run ]]; then
    exec 3>&1 4>&2
    exec > >(tee "$out/pipeline.log") 2>&1
    export TRACTSEG_WEIGHTS_DIR="${TRACTSEG_WEIGHTS_DIR:-$SCRIPT_DIR/weights}"
    export MPLCONFIGDIR="${MPLCONFIGDIR:-$out/work/matplotlib}"
    export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$out/work/cache}"
    export OMP_NUM_THREADS="$NTHREADS"
    export MKL_NUM_THREADS="$NTHREADS"
    mkdir -p "$TRACTSEG_WEIGHTS_DIR" "$MPLCONFIGDIR" "$XDG_CACHE_HOME"
    printf 'Input: %s\nMode: %s\n' "$input" "$MODE"
    TractSeg --version
    mrinfo -version
  fi
  if [[ -z "$peaks" ]]; then
    peaks="$out/work/peaks_raw.nii.gz"
    run sh2peaks "$fod" "$peaks" -num 3 -nthreads "$NTHREADS"
  fi
  run "$PYTHON" "$SCRIPT_DIR/scripts/fat_qc.py" prepare-peaks "$peaks" "$out/work/peaks.nii.gz"
  peaks="$out/work/peaks.nii.gz"
  run TractSeg -i "$peaks" -o "$out/work/xtract_model" --tract_definition xtract \
    --output_type tract_segmentation --nr_cpus "$NTHREADS"
  for pair in 'fa_l FAT_left' 'fa_r FAT_right'; do
    read -r tract name <<< "$pair"
    run "$PYTHON" "$SCRIPT_DIR/scripts/fat_qc.py" export \
      "$out/work/xtract_model/bundle_segmentations/$tract.nii.gz" \
      "$peaks" "$out/bundle_segmentations/$name.nii.gz"
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
        run "$PYTHON" "$SCRIPT_DIR/scripts/fat_qc.py" endings "$out/bundle_segmentations/$name.nii.gz" \
          "$out/endings_segmentations/${name}_b.nii.gz" "$out/endings_segmentations/${name}_e.nii.gz"
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
        roi_args=(-seed_image "$begin" -include "$begin" -include "$end" -seed_unidirectional -stop)
        if [[ -n "${ROI_DIR:-}" ]]; then
          roi_args+=(-exclude "$ROI_DIR/$tract/exclude.nii.gz")
        fi
        # Multiple MRtrix -mask options are a UNION, not an intersection.
        # Use only the undilated bundle mask, as in TractSeg's tracking code.
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
