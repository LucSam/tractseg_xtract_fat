# Frontal Aslant Tract segmentation and tracking

**Workflow author: Lucius Fekonja**

A shell workflow for reconstructing the left and right Frontal Aslant Tract (FAT)
using TractSeg's XTRACT-trained segmentation model and MRtrix3 tractography.
It retains **2000 streamlines per hemisphere and algorithm**, with every stored
point and connecting line segment inside the corresponding bundle mask.

![Anterior 3D view of both frontal aslant tracts with direction-based RGB colouring](assets/fat_3d.png)

*Anterior view of the local example, with 2000 iFOD2 streamlines per hemisphere.
Streamline colours encode local direction: red = left–right, green =
anterior–posterior, blue = inferior–superior. The translucent brain surface
provides anatomical context from the corresponding T1 image.*

`fat_simple.sh` is a **single shareable file**: the tracking commands appear first,
and the Python validation/filtering code is embedded below them.

This workflow uses software and models developed by the TractSeg, XTRACT, and
MRtrix3 teams. Authorship here refers to this workflow and its integration;
please also cite the original methods listed below.

## Requirements

- TractSeg with PyTorch and support for `--tract_definition xtract`
- MRtrix3
- Python 3 with NumPy and NiBabel
- The executables available on `PATH`

Tested locally with TractSeg 2.9, MRtrix 3.0.4-153-g4040c17b, NumPy 1.26.4,
and NiBabel 5.3.2. FSL/BEDPOSTX and a T1 image are not required for this workflow.

The first run downloads missing TractSeg model weights into `weights/` in the
current working directory and therefore requires internet access. To use an
existing model cache, set `TRACTSEG_WEIGHTS_DIR=/path/to/weights`.

## Quick start

Copy `fat_simple.sh` to your machine and run:

```bash
IN=/data/subject01/5_dwi OUT=/data/subject01/fat_output bash /path/to/fat_simple.sh
```

`OUT` must be a new directory. Without overrides, the defaults are `IN=mri` and
`OUT=fat_output`, relative to the current working directory. The script itself
can be stored anywhere; no accompanying `scripts/` directory is required.

The input directory must contain:

| File | Content |
| --- | --- |
| `peaks.nii.gz` | Three MRtrix peak vectors, stored as a 4D image with nine components |
| `wm.nii.gz` | White-matter FODs in the MRtrix spherical-harmonic convention, not a binary WM mask |

If necessary, convert FODs and generate peaks first:

```bash
mrconvert /data/subject01/5_dwi/wm.mif /data/subject01/5_dwi/wm.nii.gz
sh2peaks /data/subject01/5_dwi/wm.nii.gz /data/subject01/5_dwi/peaks.nii.gz -num 3
```

The repository does not distribute source MRI volumes or model weights. Supply
your own preprocessed diffusion-derived FODs and peaks.

## Outputs

```text
fat_output/
  bundle_segmentations/FAT_left.nii.gz
  bundle_segmentations/FAT_right.nii.gz
  iFOD2_trackings/FAT_left.tck
  iFOD2_trackings/FAT_right.tck
  SD_STREAM_trackings/FAT_left.tck
  SD_STREAM_trackings/FAT_right.tck
  qc_summary.csv
  METHOD.txt
  SUCCESS
  work/
```

Each final TCK file contains 2000 accepted streamlines. `SUCCESS` is written only
after all processing and validation steps complete. `work/` contains intermediate
peaks, model outputs, and candidate streamlines. Existing output directories are
not overwritten.

## How tracking stays inside the mask

1. Segment both FATs using `TractSeg --tract_definition xtract`. The model names
   are `fa_l` and `fa_r`, exported here as `FAT_left` and `FAT_right`.
2. Generate 4000 candidates per hemisphere and algorithm using exactly one
   undilated bundle mask, with `-downsample 1`.
3. Reject whole streamlines if any vertex or connecting line segment leaves
   the mask. No clipping, splitting, mask dilation, or duplication is performed.
4. Save 2000 accepted streamlines and validate the saved TCK file again.

The filter transforms world coordinates through the inverse NIfTI affine and
checks every voxel traversed by each straight segment, including short corner
crossings between valid vertices. Multiple MRtrix `-mask` arguments would form a
union, so the workflow passes only the bundle mask.

If fewer than 2000 valid streamlines remain, processing stops instead of relaxing
the mask or silently returning fewer tracks. Complete missing NaN peak vectors
are converted to zero vectors in a working copy; partially NaN vectors and Inf
values are rejected. Input files are not modified.

## Simple and extended workflows

Both scripts use the same default settings for their shared iFOD2/SD_STREAM steps:

| Setting | Default |
| --- | --- |
| Segmentation model | TractSeg XTRACT definition |
| Tracking mask | One unchanged FAT bundle mask |
| Candidates / final streamlines | 4000 / 2000 per hemisphere and algorithm |
| Length limits | 20–150 mm |
| FOD/peak cutoff | 0.1 |
| Downsampling factor / threads | 1 / 4 |
| Final filter | Entire polyline must remain inside the mask |

The two tested runs produced identical left/right segmentations and image geometry.
Individual streamlines differ between runs because seeds are placed randomly;
iFOD2 also samples directions probabilistically. SD_STREAM has deterministic
propagation but uses random seed locations here. Both workflows enforce the same
count and containment requirements.

`tractseg_xtract_fat.sh` additionally supports batch processing, FACT, track-density
maps, optional mean FA per streamline, external ROIs, and configurable parameters.
These additional outputs are not produced by `fat_simple.sh`.

```bash
# Inspect all options
bash tractseg_xtract_fat.sh --help

# Validate one subject, or print the planned full workflow
bash tractseg_xtract_fat.sh check /data/subject01/5_dwi
OUTPUT_DIR="$PWD/planned_run" bash tractseg_xtract_fat.sh dry-run /data/subject01/5_dwi

# Segment only, or run segmentation and tracking
bash tractseg_xtract_fat.sh segment /data/subject01/5_dwi
bash tractseg_xtract_fat.sh run /data/subject01/5_dwi

# Batch processing with both FOD algorithms
ALGORITHMS="iFOD2 SD_STREAM" bash tractseg_xtract_fat.sh run /data/subject*/5_dwi
```

The extended script requires `scripts/fat_qc.py`. Without `OUTPUT_DIR`, it writes
`<DWI_DIR>/tractseg_xtract_fat_output`. A failure stops the batch; `OUTPUT_DIR`
can only override the destination for a single input directory.

It also accepts `wm.mif` and generates missing peaks. Optional `fa.nii.gz` or
`fa.mif` inputs yield mean FA per streamline. `COMPUTE_FA=1` fits missing FA from
`dwi_den_unr_pre_unbia.mif` and `mask.nii.gz` or `mask.mif`; the preprocessed DWI
must include its gradient table in the MIF header. `DENSITY=1` adds model-predicted
density maps and requires a second model-weight download.

`ROI_DIR` may contain native-space `fa_l/{seed,target,exclude}.nii.gz` and
`fa_r/{seed,target,exclude}.nii.gz`. All six files must match the DWI grid. Seed
and target must be traversed, while the bundle mask remains the tracking boundary.
Standard-space ROIs must first be transformed and checked anatomically.

## Interpretation and limitations

TractSeg's XTRACT model supports tract segmentation and density prediction but
has no learned FAT endpoint masks or Tract Orientation Maps (TOMs).
[TractSeg documentation](https://github.com/MIC-DKFZ/TractSeg#use-different-tract-definitions)

Standard TractSeg tracking uses 2000 streamlines, an undilated bundle mask, and
additional end-region constraints; TOM tracking also uses bundle-specific
directions. These additional FAT-specific predictions are unavailable here.
[TractSeg tracking code](https://github.com/MIC-DKFZ/TractSeg/blob/master/tractseg/libs/tracking.py)

Containment alone does not establish a complete IFG–SMA/pre-SMA connection. Review
patient anatomy and reconstruction individually, particularly with tumour, oedema,
or mass effect. Streamline mean FA values are not spatially corresponding
along-tract profiles. Subsequent smoothing or compression changes the trajectory
and requires a new mask-containment check.

This is TractSeg using XTRACT training definitions. Original FSL `xtract` instead
requires BEDPOSTX samples and diffusion-to-standard-space transformations; FODs and
peaks do not replace those inputs.
[FSL XTRACT documentation](https://fsl.fmrib.ox.ac.uk/fsl/docs/diffusion/xtract.html)

## Repository contents

```text
fat_simple.sh                # standalone script with embedded Python helper
tractseg_xtract_fat.sh        # extended workflow
scripts/fat_qc.py            # helper for the extended workflow
tests/                      # regression tests and code verification
assets/fat_3d.png            # 3D preview rendered from the local example
README.md
VALIDATION.md
```

Local imaging inputs (`mri/`), results (`results/`), model downloads (`weights/`),
and the local imaging manifest are excluded from Git. The validation report
summarises local runs; their imaging files are not included in this repository.

## Verification

```bash
python3 -m unittest discover -s tests -v
bash tests/verify.sh  # also requires ShellCheck, Ruff, and mypy
```

See [VALIDATION.md](VALIDATION.md) for tested behaviour, standalone-script checks,
and the limits of the validation.

## Author and references

**Workflow author: Lucius Fekonja.**

Please acknowledge this workflow and cite the underlying methods when using it
in research:

- Wasserthal et al. (2018), *TractSeg — Fast and accurate white matter tract
  segmentation*. [DOI: 10.1016/j.neuroimage.2018.07.070](https://doi.org/10.1016/j.neuroimage.2018.07.070)
- Warrington et al. (2020), *XTRACT — Standardised protocols for automated
  tractography and connectivity blueprints in the human and macaque brain*.
  [DOI: 10.1016/j.neuroimage.2020.116923](https://doi.org/10.1016/j.neuroimage.2020.116923)
- Tournier et al. (2019), *MRtrix3: A fast, flexible and open software framework
  for medical image processing and visualisation*.
  [DOI: 10.1016/j.neuroimage.2019.116137](https://doi.org/10.1016/j.neuroimage.2019.116137)
