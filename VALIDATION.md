# Validation

**Workflow author: Lucius Fekonja**

## Current run

The current implementation replaces the TractSeg/XTRACT bundle boundary with
registered **HCP1065 population-probability FAT masks**. It uses Harvard-Oxford
IFG pars opercularis/triangularis and SFG plus SMA as cortical targets, with a
3 mm endpoint margin. Bundle processing uses a 5% probability threshold, the
largest component (at least 95% of threshold support), a bounded 3 mm margin
and Gaussian sigma 1 mm.

Current local outputs: **`results/hcp1065_fat/`**. The complete standalone run
finished with **exit 0** and `SUCCESS`. An independently invoked post-run check
of all four saved tractograms also finished with **exit 0**.

The HCP1065 registration to **ICBM2009a nonlinear asymmetric T1** was estimated
for this individual during this validation. Existing transforms from the same
subject were explicitly reused for Harvard-Oxford/FSL MNI152 and T1-to-DWI.
The FSL MNI152 warp was not used for the HCP1065 probabilities. Template/T1
orthogonal views and native-space mask overlays were inspected. Whole-brain
support Dice between the registered T1 and ICBM template was 0.978; this checks
global alignment and does not validate local cortical/tract alignment.

A stable copy of the standalone script was executed. The final distributed file
has the same executable body; two atlas-attribution comments were subsequently
added to its shell header. Source hashes and that comparison are recorded in
`tracking_validation.json`.

## Saved tractograms

| Hemisphere | Algorithm | Complete streamlines | Outside processed mask | Incorrect endpoint pairs |
| --- | --- | ---: | ---: | ---: |
| Left | iFOD2 | 2000 | 0 | 0 |
| Left | SD_STREAM | 2000 | 0 | 0 |
| Right | iFOD2 | 2000 | 0 | 0 |
| Right | SD_STREAM | 2000 | 0 | 0 |

The checks inspect every stored vertex and the voxels crossed by every connecting
segment. The first and last points must lie in opposite expanded cortical regions.
Whole tracks failing either condition are discarded; none are clipped, joined,
bent or duplicated. The saved files establish complete geometric connections
under these constraints, not anatomical completeness or correctness.

## Width compared with the previous XTRACT run

The previous comparator is `results/bidirectional_fat/`: its tracking was already
bidirectional and used the same FODs, cutoff 0.05 and streamline target. The new
run changes both the bundle prior and cortical target definition. This is not a
controlled comparison of atlas choice alone.

Anterior–posterior width below is the **5th-to-95th percentile range of streamline
point y-coordinates**, in the same native world coordinate system. It measures
spatial spread, not streamline length.

| Hemisphere / algorithm | Previous AP width (mm) | HCP1065 AP width (mm) | Previous median length (mm) | HCP1065 median length (mm) |
| --- | ---: | ---: | ---: | ---: |
| Left iFOD2 | 25.38 | 34.58 | 76.17 | 89.76 |
| Right iFOD2 | 22.69 | 34.36 | 80.90 | 83.89 |
| Left SD_STREAM | 21.37 | 28.20 | 73.35 | 84.15 |
| Right SD_STREAM | 17.44 | 36.80 | 77.25 | 76.80 |

**The additional width is predominantly posterior.** For right iFOD2 the point
range changes from y=25.02–47.71 mm to 12.31–46.67 mm. The manual reference covers
25.77–70.57 mm by the same measure. Thus the new reconstruction is broader, but
does not recover the reference's most anterior extension.

## Manual right reference

The author's `mri/fat_sd.tck` contains **2000 iFOD2** streamlines at cutoff 0.1,
with manual seed, inclusion and exclusion ROIs, without a bundle mask. It is
right-sided; the filename does not identify the tracking algorithm. Median
length is 78.79 mm. It is a useful comparator, not an independent anatomical
ground truth, and it cannot validate the left side.

| Right mask | Whole reference streamlines contained | Median reference length fraction inside |
| --- | ---: | ---: |
| Previous processed XTRACT | 236 / 2000 | 70.9% |
| New processed HCP1065 | 571 / 2000 | 90.2% |

Whole-track containment was checked exactly. Length fractions were sampled at
0.25 mm along each reference streamline. The improvement is substantial, but
1429 reference tracks still leave the HCP1065 mask somewhere. The current right
tracking mask extends to anterior y=61.90 mm; the full manual tractogram reaches
y=92.93 mm. The workflow was not expanded to encompass that entire manual result.

## Mask topology and volumes

| Hemisphere | Raw 5% volume (ml) | Raw components (6-neighbour) | Discarded island voxels | Final volume (ml) | Final components | Final enclosed cavity voxels |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Left | 50.585 | 2 | 137 | 91.047 | 1 | 2 |
| Right | 33.861 | 3 | 19 | 65.384 | 1 | 1 |

The retained main components contain 99.09% and 99.81% of the thresholded voxels.
Final masks are face-connected. The two left and one right enclosed voxels remain
because filling is limited by the explicit physical distance bound; the masks
are therefore **not described as cavity-free**. Cavities occupy 6.75 mm³ left and
3.375 mm³ right. A connected mask can also contain tunnels and narrow passages.

These are broad **tracking support masks**, not estimates of individual tract
volume. The previous processed XTRACT volumes were 12.768 ml left and 15.390 ml
right. This large change must be considered when interpreting extra trajectories.
The final hard containment mask is the processed mask, not the raw atlas threshold.

An initial HCP1065 run with a 1.5 mm margin yielded few left connections and was
stopped before completion. A 50,000-seed probe using the whole mask produced only
15 candidates. Keeping the same cortical constraints and increasing the mask
margin to 3 mm produced 200 candidates within 7455 seed attempts in a bounded
probe. The final workflow uses 3 mm; it does not silently retry larger
margins or weaker thresholds after failure. These exploratory observations on one
subject do not establish an optimal threshold or margin for other patients.

## Cortical target volumes

All volumes are measured in the individual's 1.5 mm diffusion grid. `_b` is IFG
pars opercularis/triangularis; `_e` is SFG plus SMA. Full cortical regions are saved
before dilation, and only separate seed masks are intersected with the bundle.

| Region | Registered cortex (ml) | Cortex + 3 mm (ml) | Intersection with tracking mask (ml) |
| --- | ---: | ---: | ---: |
| Left b | 10.020 | 20.260 | 14.273 |
| Left e | 26.251 | 49.542 | 29.714 |
| Right b | 8.147 | 16.787 | 11.418 |
| Right e | 24.425 | 46.285 | 23.038 |

For context, existing standard TractSeg endpoint masks measured in this same
example had full b/e volumes of 12.842/8.569 ml for left UF, 14.118/10.449 ml for
left SLF III, and 17.418/6.956 ml for left CST. These are different tracts; identical
absolute volumes would not be expected. The new FAT targets represent complete
cortical atlas regions rather than the earlier geometric caps.

The broader SFG region includes medial and dorsal anatomy, but does not reproduce
the custom cortical parcels in [Tagliaferri et al. (2024)](https://doi.org/10.1007/s00429-024-02778-4).
Expanded ROI contact does not prove that a streamline terminates in cortical grey
matter itself. No learned FAT endpoint model or TOM is used.

## Review files and automated verification

In `results/hcp1065_fat/`:

- `comparison_3d.html`: self-contained, rotatable viewer with both sides, iFOD2,
  SD_STREAM, previous XTRACT tracks and the manual right reference. It displays
  500 of each file's 2000 streamlines; source TCK files are unchanged. Initial
  anterior view: anatomical right appears on the left of the screen.
- `bilateral_front.png`, `left_oblique.png`, `right_oblique.png`, `right_front.png`,
  `manual_right_oblique.png`: native 3D renders, direction RGB, black background.
- `tracking_validation.json`, `mask_validation.json`, `roi_qc.csv`,
  `qc_summary.csv`, `independent_validation.log`: measurements and checks.
- `work/atlas/registration.json`: transform provenance and actual commands.

Registration and exploratory logs remain in `results/hcp1065_registration/`.
The incomplete 1.5 mm pilot is separately retained in
`results/archive/hcp1065_margin1p5_pilot/`; it has no `SUCCESS` marker.

```bash
bash tests/verify.sh
```

Current software verification: **41 tests passed; zero ShellCheck/Ruff warnings; zero mypy
errors; `git diff --check` clean.** Tests include probability scale validation,
small-island accounting, rejection of major disconnected components, physical
mask bounds, atlas checksums, separate ICBM/FSL transformation chains, cortical
label indexing, complete-polyline containment, endpoint pairs, insufficient
counts, standalone helper embedding, and both shell workflows' tracking commands.

This validation covers one individual. The tumour is right-sided according to the
dataset owner; the earlier left reconstruction failure is not evidence of a
left tumour or anatomical transection. Broader priors and successful geometric
checks can also admit false-positive trajectories. General applicability, local
registration near pathology and anterior extended-FAT coverage remain unvalidated.
Density prediction, FA fitting and external ROI overrides have not been newly
tested on real data in this revision. FACT and tensor tracking are covered below.

## Installation tutorial checks

The publication update adds an eight-step English README tutorial. Its shell
blocks were parsed with macOS system Bash; the dependency check and input check
were executed successfully on the existing local installation. Conda dry-runs
successfully resolved the documented Python/ANTs packages on macOS Intel and the
combined Python/ANTs/MRtrix3 stack for Linux x86_64. These were package-resolution
checks, not fresh full installations on both operating systems. FSL and macOS
MRtrix installer commands were checked against their official instructions.
No new tractography parameters were changed by the documentation/cleanup update.

Old local experiments were moved under `results/archive/`; the current
`results/hcp1065_fat/`, its registration records and the previous XTRACT comparator
remain directly accessible. The atlas cache is retained for offline reuse.

## Tracking comparison and public viewer — 12 September 2026

The [public 3D viewer](https://LucSam.github.io/tractseg_xtract_fat/) compares
**iFOD2, SD_STREAM, FACT, Tensor_Det and Tensor_Prob**. Each method has two source
TCK files with **2000 whole streamlines per side**. A fixed quarter (500 per side)
is exported for interactive display, with direction RGB and a brain surface.
The README contains one preview linked to the viewer. No JavaScript executes
inside GitHub's README renderer.

FACT and tensor results are stored locally in `results/hcp1065_algorithms/`.
The masks and end regions match the HCP1065 iFOD2/SD_STREAM run. All six additional
TCK files passed whole-polyline containment and opposite-endpoint checks.
`independent_validation.log` and `validated_algorithms.json` record this check.

Tensor tracking used the example's preprocessed DWI with its embedded gradients:
7 near-b0 volumes plus 46 directions at approximately b=1500 s/mm²; the b=3000
shell was excluded. Tensor stopping FA was 0.1. The first Tensor_Det left trial
retained 1620/2000 tracks from 4000 candidates. Raising the candidate target to
8000 supplied the requested 2000 without changing the masks or endpoint rules.
Both tensor algorithms passed on both sides with that target. FACT used a peak
amplitude cutoff of 0.05 and 4000 candidates.

A subsequent Trekker rc6 prototype was stopped after a short, low-yield pilot.
Its incomplete outputs and logs are archived under `results/archive/trekker_pilot/`.
They are excluded from the published viewer and from the successful MRtrix
validation. Trekker is not part of the released script. TractSeg's own TOM tracker
is also not included because the atlas workflow has no learned FAT TOM.

The website data exporter rechecks the 2000-streamline count, every crossed voxel,
endpoints and equality of comparison masks before exporting display geometry.
Rebuild from local validated results (requires Plotly and scikit-image):

```bash
python3 scripts/build_viewer.py \
  --fod-results results/hcp1065_fat \
  --extra-results results/hcp1065_algorithms
```

These results establish geometric constraints in this one example. Different
tracking models can produce different shapes and false positives inside the same
mask; the viewer is a method comparison, not an anatomical validation.

Browser checks passed for all five algorithms, displayed counts, side selection,
brain visibility, camera retention and reset, and desktop/mobile layouts.
The five MRtrix methods have no remaining validation failures in this example;
Trekker and TractSeg TOM tracking remain unavailable as described above.
