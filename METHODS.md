# Method

Author: Lucius Fekonja · [Usage and installation](README.md)

## Atlas preparation

`bash fat.sh --setup-atlas` installs HCP1065 FAT probability maps and the
ICBM2009a asymmetric T1 template. Archive downloads have pinned SHA-256 checksums.
The installation records checksums for the extracted FAT maps, brain template
and template license. Each tracking run verifies these installed resources.

## Registration

ANTs registers the individual's brain-extracted T1 to ICBM2009a for the HCP1065
maps and separately to FSL MNI152 for the Harvard-Oxford cortical labels. A rigid
T1-to-diffusion registration completes the mapping into the FOD grid.

Atlas-to-diffusion transforms are applied in this order: inverse nonlinear
T1-to-template warp, inverse T1-to-template affine, then T1-to-diffusion affine.
Probability maps use linear interpolation; cortical labels use nearest-neighbour
interpolation. `work/atlas/registration.json` records the transform paths and
ANTs commands. `work/atlas/t1_dwi.nii.gz` provides the T1 in diffusion space for
inspection.

To reuse transforms from the same subject and image spaces:

```bash
bash fat.sh --input /data/subject01/mri --output /data/subject01/fat_reuse \
  --t1-to-mni-prefix /data/subject01/transforms/T1toMNI_ \
  --t1-to-icbm-prefix /data/subject01/transforms/T1toICBM2009a_ \
  --t1-to-dwi-affine /data/subject01/transforms/T1toDWI_0GenericAffine.mat
```

Each template prefix must provide `0GenericAffine.mat` and
`1InverseWarp.nii.gz`. The two template registrations have separate prefixes.

## Bundle masks

The default HCP1065 probability threshold is 0.05 (`--mask-threshold`).
Thresholded maps are saved in `bundle_segmentations_original/`.

The largest face-connected component must contain at least 95% of thresholded
voxels. It is expanded by a physical distance of 3 mm (`--mask-margin`), smoothed
with a 1 mm Gaussian sigma and thresholded at 0.5. The retained component is
preserved, and cavity filling is bounded by the selected margin. The resulting
tracking mask must be face-connected and is saved in `bundle_segmentations/`.

## Cortical regions

The Harvard-Oxford maximum-probability cortical atlas (25% threshold, 1 mm)
defines two targets in each hemisphere:

- `_b`: inferior frontal gyrus, pars opercularis and pars triangularis.
- `_e`: superior frontal gyrus and juxtapositional lobule cortex (SMA).

The registered regions are saved in `anatomical_rois/`. A default 3 mm expansion
(`--roi-margin`) produces `endings_segmentations/`. Their intersections with the
bundle mask are saved in `seed_masks/`. Both regions must reach the bundle mask,
and their intersections within it must be separate.

## Tracking

The default algorithm is MRtrix3 iFOD2. SD_STREAM, FACT, Tensor_Det and Tensor_Prob
are selected with `--algorithm`. FACT uses three FOD peaks. Tensor methods use
b=0 and the lowest nonzero DWI shell, with an FA cutoff of 0.1 (`--tensor-fa`).
The FOD/peak amplitude cutoff defaults to 0.05 (`--cutoff`).

Tracking is seeded in the `_b` intersection, propagates in both directions from
the seed and requires passage through both end regions. The processed bundle
mask constrains propagation. Streamline lengths default to 20–150 mm
(`--min-length`, `--max-length`).

The final target is 2000 streamlines per side and algorithm (`--streamlines`).
The candidate budget is twice this count for iFOD2, SD_STREAM and FACT, and four
times for tensor tracking; `--candidates` sets an explicit count. Every retained
streamline must remain inside the bundle mask along all vertices and connecting
segments, and its two endpoints must lie in opposite end regions.

`run.json` records the chosen settings. `commands.log` records the workflow
commands; `work/atlas/registration.json` records the ANTs commands.
`SUCCESS` marks completion of all requested reconstructions and checks.

## References

- Yeh FC (2022). [Population-based tract-to-region connectome of the human brain and its hierarchical topology](https://doi.org/10.1038/s41467-022-32595-4).
- [HCP1065 atlas](https://brain.labsolver.org/hcp_trk_atlas.html).
- [ICBM2009 templates](https://www.bic.mni.mcgill.ca/ServicesAtlases/ICBM152NLin2009).
- [FSL Harvard-Oxford atlas](https://fsl.fmrib.ox.ac.uk/fsl/docs/other/datasets.html).
- [ANTs registration](https://github.com/ANTsX/ANTs).
- [MRtrix3 tckgen algorithms and parameters](https://mrtrix.readthedocs.io/en/latest/reference/commands/tckgen.html).
