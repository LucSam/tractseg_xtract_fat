# Method and advanced usage

**Workflow author: Lucius Fekonja**

For installation and your first reconstruction, start with the [README tutorial](README.md#install).
See [VALIDATION.md](VALIDATION.md) for measured results and limitations.

## Bundle masks

The [HCP1065 population-probability atlas](https://brain.labsolver.org/hcp_trk_atlas.html)
provides left and right FAT maps in **ICBM2009a nonlinear asymmetric space**.
The workflow registers the matching brain-extracted T1 template to the individual
via the inverse of a subject-T1-to-template registration, then applies the
subject's T1-to-DWI rigid transform. Probabilities use linear interpolation.
The previous XTRACT mask is not intersected with this new prior.

In diffusion space, the workflow:

1. Saves the unthresholded probabilities in `work/atlas/`.
2. Thresholds at **0.05**, saving all threshold voxels in `bundle_segmentations_original/`.
3. Keeps the largest face-connected component only if it contains at least **95%**
   of those voxels. Removed islands are recorded; larger disconnections fail.
4. Adds a bounded **3 mm physical margin**, smooths with Gaussian **sigma 1 mm**
   and thresholds at 0.5. The retained original component is preserved. Enclosed
   cavity filling is limited to that distance bound.
5. Requires a face-connected result and saves it in `bundle_segmentations/`.

The 5% threshold and 3 mm registration margin are explicit workflow settings,
**not validated anatomical FAT boundaries**. The wider atlas prior allows more
candidate trajectories. It does not guarantee all anterior extensions found by a
broader manual or extended-FAT protocol. See [VALIDATION.md](VALIDATION.md).

## Cortical targets and registration

The FSL Harvard-Oxford cortical max-probability atlas at 25% supplies:

| Region | Definition |
| --- | --- |
| `_b` | Inferior frontal gyrus: pars opercularis + pars triangularis |
| `_e` | Superior frontal gyrus + juxtapositional lobule cortex (SMA) |

Each region is split by hemisphere in atlas world coordinates and transformed
with nearest-neighbour interpolation. SFG includes medial and dorsal portions;
it is not restricted to the former medial BA6 strip. These are population
anatomical labels, not individual functional boundaries or learned FAT endings.
The definition is not an exact reproduction of the custom parcels in
[Tagliaferri et al. (2024)](https://doi.org/10.1007/s00429-024-02778-4).

**Two distinct template registrations are necessary:** Harvard-Oxford uses FSL
MNI152; HCP1065 uses ICBM2009a. Their inverse warps are not interchangeable.
Both are composed with the same T1-to-DWI rigid transform, using FOD coefficient
zero as the diffusion reference. Inspect `work/atlas/t1_dwi.nii.gz`, the cortical
labels and the bundle probabilities against the subject's anatomy.
[HCP template coordinate systems](https://brain.labsolver.org/hcp_template.html)

Outputs preserve full cortex labels in `anatomical_rois/`, cortex plus a **3 mm
margin** in `endings_segmentations/`, and their intersections with the bundle in
`seed_masks/`. The first and last streamline points must occupy opposite expanded
regions. This does not establish termination inside cortical grey matter itself.

Optional transform reuse, **only for the same subject and the correct templates**:

```bash
T1_TO_ICBM_PREFIX=/data/subject01/reg/T1toICBM2009a_ \
T1_TO_MNI_PREFIX=/data/subject01/reg/T1toFSLMNI_ \
T1_TO_DWI_AFFINE=/data/subject01/reg/T1toDWI_0GenericAffine.mat \
IN=/data/subject01/mri OUT=/data/subject01/fat_output bash fat_simple.sh
```

Each nonlinear prefix supplies `0GenericAffine.mat` and `1InverseWarp.nii.gz`.
Omit these variables to estimate transforms automatically. File existence alone
does not establish their provenance; `work/atlas/registration.json` records the
files and actual commands used.

## Tracking and checks

The standalone script runs **iFOD2, SD_STREAM and FACT**. It seeds the
inferior-frontal ROI/bundle intersection, grows in both directions and requires
both cortical inclusion regions. It uses **one** processed bundle `-mask`.
There is no early ROI stopping. Defaults: 20–150 mm, cutoff 0.05, 4000 candidates,
2,000,000 maximum seed attempts, `-downsample 1`, four threads.

A final filter retains exactly **2000 whole streamlines** whose first/last points
occupy opposite expanded cortical regions and whose complete polylines remain
inside the mask. It checks every crossed voxel, including short corner crossings.
There is no clipping, joining, duplication or streamline smoothing. A shortfall
raises an error. `SUCCESS` appears only after every requested output passes.
Partial work may remain after failure; inspect the error and choose a fresh output
folder for another run.

The 2000-streamline target and cutoff 0.05 follow TractSeg's FOD tracking defaults;
this is still an atlas-guided MRtrix workflow, not TractSeg TOM tracking.
[TractSeg tracking implementation](https://github.com/MIC-DKFZ/TractSeg/blob/master/tractseg/libs/tracking.py),
[MRtrix tckgen](https://mrtrix.readthedocs.io/en/latest/reference/commands/tckgen.html)

```text
fat_output/
  bundle_segmentations_original/FAT_{left,right}.nii.gz
  bundle_segmentations/FAT_{left,right}.nii.gz
  bundle_segmentations/FAT_{left,right}.json
  anatomical_rois/FAT_{left,right}_{b,e}.nii.gz
  endings_segmentations/FAT_{left,right}_{b,e}.nii.gz
  seed_masks/FAT_{left,right}_{b,e}.nii.gz
  iFOD2_trackings/FAT_{left,right}.tck
  SD_STREAM_trackings/FAT_{left,right}.tck
  FACT_trackings/FAT_{left,right}.tck
  qc_summary.csv
  roi_qc.csv
  METHOD.txt
  SUCCESS
  work/atlas/
```

The JSON/CSV files record mask processing, volumes, connectivity and ROI overlap.
These geometric checks do not establish anatomical correctness. Registration needs
individual review, especially with mass effect. A reconstruction failure does not
prove anatomical tract interruption.

## Extended workflow

`tractseg_xtract_fat.sh` uses the same HCP1065 preparation and tracking defaults,
with an external copy of the embedded helper. It adds batch processing, optional
tensor tracking, track densities, mean FA and native ROI overrides. It accepts `wm.mif` and
can generate missing peaks. This alternative requires the repository; sharing
the standalone script remains sufficient for iFOD2/SD_STREAM/FACT.

```bash
bash tractseg_xtract_fat.sh --help
bash tractseg_xtract_fat.sh check /data/subject01/mri
OUTPUT_DIR="$PWD/planned_run" bash tractseg_xtract_fat.sh dry-run /data/subject01/mri
bash tractseg_xtract_fat.sh segment /data/subject01/mri
ALGORITHMS="iFOD2 SD_STREAM" bash tractseg_xtract_fat.sh run /data/subject*/mri
```

`segment` performs atlas registration and prepares the bundle masks; `run` adds
endpoint masks and tracking. A failure stops the batch. `OUTPUT_DIR` is allowed
for one input only; otherwise outputs go to `<DWI_DIR>/tractseg_xtract_fat_output`.

`ROI_DIR` supplies native `fa_l/{seed,target,exclude}.nii.gz` and
`fa_r/{seed,target,exclude}.nii.gz`; all six must match the diffusion grid. These
override the cortical tracking constraints; atlas bundle registration still runs.
`DENSITY=1` optionally runs TractSeg/XTRACT density prediction for comparison and
therefore requires TractSeg/weights. It does not change the HCP1065 tracking masks.
`COMPUTE_FA=1` fits absent FA from `dwi_den_unr_pre_unbia.mif` and a brain mask.
Mean FA per streamline is not an anatomically corresponding along-tract profile.

### Additional algorithms

Tensor_Det and Tensor_Prob take DWI with embedded gradients, after extraction of
b=0 and the lowest nonzero shell. Both use `TENSOR_FA=0.1` and generate four times
the requested final count; other algorithms generate twice the final count.
FACT uses cleaned three-peak images. All MRtrix modes share mask and endpoint
checks. See the [algorithm tutorial](README.md#tracking-algorithms).
