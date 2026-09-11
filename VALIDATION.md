# Validation

**Workflow author: Lucius Fekonja**

## Tested final outputs

Both workflows were run end to end with the local example dataset using
TractSeg 2.9 and MRtrix 3.0.4-153-g4040c17b, with four threads.

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

## Comparison of workflows

The two runs produced exactly identical FAT segmentations: 2012 voxels on the
left and 2526 on the right, with identical image geometry. The TCK files differ
because seed positions are random and iFOD2 additionally samples directions
probabilistically. Both scripts use the same default iFOD2/SD_STREAM parameters
and the same final containment filter.

FACT, density maps, and optional FA summaries are additional features of the
extended workflow, rather than outputs of the simple script.

## Automated checks

- 21 regression tests passed.
- ShellCheck and Ruff reported no issues.
- mypy reported no type errors.
- Tests cover mask-union errors, outside vertices, segments crossing mask holes,
  very short diagonal boundary crossings, oblique image geometry, grid mismatches,
  NaN handling, and insufficient accepted streamline counts.

```bash
bash tests/verify.sh
```

The verification script requires ShellCheck, Ruff, and mypy in addition to the
runtime dependencies. `SHELLCHECK=/path/to/shellcheck` can select a specific binary.

## Standalone distribution

`fat_simple.sh` contains its complete Python helper and does not require an
external `scripts/` directory. A regression test checks that its embedded code
matches the verified helper used by the extended workflow exactly.

The standalone test copies only `fat_simple.sh` into a separate directory, validates
synthetic input images, and filters a TCK file using the embedded helper. The saved
tractogram is then checked for streamline count and mask containment. Shell syntax,
ShellCheck, Python lint, and type checks pass. Embedding the helper did not change
tracking parameters or filtering algorithms, so no new model inference was needed
for that packaging change.

The original failed runs and intermediate files were removed during cleanup.
Thirty-five retained final result files were checked by SHA-256 to confirm they
were unchanged when moved into the local `results/` directory. Original execution
paths may still appear in those local logs.

## Limits

The optional `DENSITY=1`, `COMPUTE_FA=1`, and external anatomical ROI branches were
not run against additional real data. The FAT model has no learned endpoint
masks or TOMs, and containment does not establish anatomical completeness or
endpoint correspondence.

Validation applies to the stored TCK polyline. Smoothing or compression changes
its trajectory and requires a new check. `tckmap -precise` internally interpolates
Hermite curves and can introduce outside contributions; the regular density maps
omit `-precise` and use `-upsample 1` to avoid additional upsampling.
