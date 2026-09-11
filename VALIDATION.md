# Validation

**Workflow author: Lucius Fekonja**

## Current endpoint-constrained workflow

The current scripts require each streamline to start and end in opposite end
regions, as well as remaining entirely inside the bundle mask. End regions are
computed from the terminal 15% of the mask's principal axis in physical space.
They are geometric ROIs, not independently labelled IFG/SMA cortex.

The revised tracking and filtering commands were tested on the already computed
individual masks and FODs; model inference was unchanged and was not repeated.
The local outputs are under `results/connected_strict/`.

| Right FAT algorithm | Candidates | Final streamlines | Mask violations | Wrong endpoint pairs |
| --- | ---: | ---: | ---: | ---: |
| iFOD2 | 4000 | 2000 | 0 | 0 |
| SD_STREAM | 4000 | 2000 | 0 | 0 |

The right end regions contain 222 beginning and 339 ending voxels; the left
regions contain 85 and 371 voxels. The original masks are unchanged. The README
preview now uses the revised right iFOD2 result.

The left side produced **zero connecting candidates with a limit of two million
seed attempts** using the same iFOD2 parameters and original mask. The filter
reported `Only 0/2000 valid streamlines` and wrote neither a final left tractogram
nor a global `SUCCESS` marker. An earlier 50,000-seed probe also found none. End regions prevent
partial tracks being reported as complete, but cannot manufacture a missing
FOD-supported route inside the mask. The public workflow does not automatically
expand the mask, lower the cutoff, join fragments, or fall back to partial tracks.

A separate exploratory mask-expansion test did not change the production masks
or scripts. Any mask correction needs individual anatomical review. The tumour
is on the right according to the dataset owner; the left failure is not evidence
of a tumour-related tract interruption.

## Earlier mask-only outputs

Before endpoint constraints were added, both workflows were run end to end
with the local example dataset using TractSeg 2.9 and MRtrix 3.0.4-153-g4040c17b, with four threads.

| Local output directory | Algorithms | Streamlines per hemisphere/algorithm | Mask violations |
| --- | --- | ---: | ---: |
| `results/simple/` | iFOD2, SD_STREAM | 2000 | 0 |
| `results/extended/` | iFOD2, SD_STREAM, FACT | 2000 | 0 |

Validation covered stored vertices and every voxel traversed by the connecting
line segments. A separate dense sampling check, with a maximum spacing of 0.02
voxel, found zero outside points among 7,233,879 sampled points in the simple run.

The extended workflow additionally produced 2000 finite mean FA values per
hemisphere and algorithm. Its final density maps contained no occupied voxels
outside the bundle masks. Both runs exited with code 0 and wrote `SUCCESS`.

These MRI-derived outputs are stored locally and are excluded from Git. This
report summarises the checks; the repository does not distribute the dataset.

## Comparison of the earlier workflows

The two runs produced exactly identical FAT segmentations: 2012 voxels on the
left and 2526 on the right, with identical image geometry. The TCK files differ
because seed positions are random and iFOD2 additionally samples directions
probabilistically. Those earlier scripts used the same default iFOD2/SD_STREAM
parameters and the same final containment filter, without mandatory endpoint checks.

FACT, density maps, and optional FA summaries are additional features of the
extended workflow, rather than outputs of the simple script.

## Local example: left FAT discontinuity

The README preview displays the **right FAT only**. The left reconstruction in
this tumour example appears interrupted. Both binary bundle masks are single
connected components even under face-only (6-neighbour) connectivity, so the
appearance cannot be explained by a disconnected segmentation alone.

An exploratory tracking comparison used two regions within the left bundle
mask: its lateral portion at world RAS x < -38 mm and its medial portion at
x > -24 mm. These are diagnostic coordinate-based regions, not validated
IFG/SMA endpoint ROIs. Neither of the original 2000-streamline left iFOD2 and
SD_STREAM outputs contained a streamline visiting both regions.

Two additional iFOD2 runs generated 4000 candidates each with the workflow's
seed mask, length limits, cutoff, and other tracking settings. Only the tracking
boundary mask was omitted in the second run; no final containment filter was
applied before this comparison.

| Tracking boundary | Candidates | Visiting both regions | Connecting segment entirely inside the bundle mask |
| --- | ---: | ---: | ---: |
| Left FAT mask | 4000 | 0 | 0 |
| No boundary mask | 4000 | 88 | 0 |

These stochastic runs support a contribution from the tracking boundary to the
missing connection. The whole-track filter does not split streamlines, and the
masked candidates already lacked connections before filtering. Unrestricted
connections are not evidence of anatomically correct FAT fibres. This comparison
does not establish whether tumour, oedema, FOD estimation, or segmentation
accounts for the mismatch between candidate paths and the bundle mask. It also
does not demonstrate anatomical tract destruction. Counts and containment alone
do not establish a complete FAT reconstruction.

## Automated checks

- 27 regression tests passed.
- ShellCheck and Ruff reported no issues.
- mypy reported no type errors.
- Tests cover mask-union errors, outside vertices, segments crossing mask holes,
  very short diagonal boundary crossings, oblique image geometry, grid mismatches,
  NaN handling, and insufficient accepted streamline counts.
- New checks cover end-region generation in flipped/oblique world coordinates,
  disconnected masks, overlapping ROIs, fragments, tracks that only visit ROIs
  internally, reversed endpoint order, and standalone end-region CLI usage.

```bash
bash tests/verify.sh
```

The verification script requires ShellCheck, Ruff, and mypy in addition to the
runtime dependencies. `SHELLCHECK=/path/to/shellcheck` can select a specific binary.

## Standalone distribution

`fat_simple.sh` contains its complete Python helper and does not require an
external `scripts/` directory. A regression test checks that its embedded code
matches the verified helper used by the extended workflow exactly.

Standalone tests copy only `fat_simple.sh` into a separate directory, validate
synthetic input images, derive end regions, and filter a TCK file using the
embedded helper. Saved tracks are checked for count, containment, and opposite
endpoints. Shell syntax, ShellCheck, Python lint, and type checks pass.

The original failed runs and intermediate files were removed during cleanup.
Thirty-five retained final result files were checked by SHA-256 to confirm they
were unchanged when moved into the local `results/` directory. Original execution
paths may still appear in those local logs.

## Limits

The current endpoint-constrained FACT branch and the optional `DENSITY=1`,
`COMPUTE_FA=1`, and external anatomical ROI branches were not validated on
additional real data. The FAT model has no learned endpoint
masks or TOMs, and containment does not establish anatomical completeness or
endpoint correspondence.

Validation applies to the stored TCK polyline. Smoothing or compression changes
its trajectory and requires a new check. `tckmap -precise` internally interpolates
Hermite curves and can introduce outside contributions; the regular density maps
omit `-precise` and use `-upsample 1` to avoid additional upsampling.
