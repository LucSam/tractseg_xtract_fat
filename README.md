# Frontal Aslant Tract reconstruction

Author: **Lucius Fekonja** · [LucSam on GitHub](https://github.com/LucSam)

Reconstruct the frontal aslant tract (FAT) from individual white-matter FODs
and a brain-extracted T1, using HCP1065 atlas masks and cortical target regions.
`fat.sh` runs iFOD2 with 2000 streamlines per side by default. Tracking algorithms,
streamline counts and mask settings are selectable through command-line options.

[![FAT in direction RGB — open the 3D viewer](assets/fat_3d.png)](https://lucsam.github.io/tractseg_xtract_fat/)

[Open the 3D viewer](https://lucsam.github.io/tractseg_xtract_fat/) to rotate the
tracts and select iFOD2, SD_STREAM, FACT, Tensor_Det or Tensor_Prob.

## Table of contents

- [Install](#install)
- [How to use](#how-to-use)
- [Options](#options)
- [FAQ](#faq)
- [Method](METHODS.md)
- [References](#attribution)

## Install

Use a Bash or Zsh terminal on macOS or Linux. On Windows, use
[WSL with Ubuntu](https://fsl.fmrib.ox.ac.uk/fsl/docs/install/windows.html).
Run one block at a time and skip software installation steps you have already
completed. The prerequisites are Python with NumPy, NiBabel and SciPy, ANTs,
MRtrix3, FSL's Harvard-Oxford atlas, and the atlas files prepared in step 6.

### 1. Install Conda if needed

If `conda --version` already works, use that Conda installation and skip the
installer block. Otherwise install [Miniforge](https://github.com/conda-forge/miniforge)
with the following commands; the installer is selected for your computer:

```bash
mkdir -p "$HOME/Downloads/fat_setup"
cd "$HOME/Downloads/fat_setup"
case "$(uname -s)" in
  Darwin) FAT_PLATFORM=MacOSX ;;
  Linux) FAT_PLATFORM=Linux ;;
esac
curl -L --fail -o Miniforge3.sh \
  "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-${FAT_PLATFORM}-$(uname -m).sh"
bash Miniforge3.sh -b -p "$HOME/miniforge3"
source "$HOME/miniforge3/etc/profile.d/conda.sh"
```

This creates `~/miniforge3`. If that directory already exists, use the existing
installation instead of running its installer again.

### 2. Create the FAT environment: Python and ANTs

```bash
conda create -n fat --override-channels -c conda-forge \
  python=3.12 numpy nibabel scipy ants git curl
conda activate fat
```

Confirm Conda's proposed installation when prompted. This environment supplies
the Python packages and ANTs registration commands, including
`antsRegistrationSyNQuick.sh` and `antsApplyTransforms`.
[ANTs conda package](https://github.com/conda-forge/ants-feedstock)

### 3. Install MRtrix3

Choose the block for your operating system. If `mrinfo -version` and
`tckgen -version` already work in the active `fat` environment, continue to step 4.

**Linux x86_64:** install the official MRtrix3 Conda package into `fat`:

```bash
conda install -n fat --override-channels -c conda-forge -c MRtrix3 \
  mrtrix3 libstdcxx-ng
```

[Official Linux instructions](https://www.mrtrix.org/download/linux-anaconda/)

**macOS:** use MRtrix3's application installer. Download the installer, then run
it; `sudo` requests your Mac administrator password:

```bash
mkdir -p "$HOME/Downloads/fat_setup"
curl -L --fail -o "$HOME/Downloads/fat_setup/install_mrtrix3" \
  https://raw.githubusercontent.com/MRtrix3/macos-installer/master/install
sudo bash "$HOME/Downloads/fat_setup/install_mrtrix3"
export PATH="$PATH:/usr/local/bin"
```

It installs command-line tools and MRview. Afterwards, reactivate the environment
so its Python remains first on `PATH`:

```bash
conda activate fat
mrinfo -version
tckgen -version
```

[Official macOS instructions](https://www.mrtrix.org/download/macos-application/)

### 4. Install FSL and its cortical atlas

An existing FSL installation containing Harvard-Oxford and the standard MNI152
T1 template is sufficient. Otherwise, use the official installer:

```bash
mkdir -p "$HOME/Downloads/fat_setup"
curl -L --fail -o "$HOME/Downloads/fat_setup/getfsl.sh" \
  https://fsl.fmrib.ox.ac.uk/fsldownloads/fslconda/releases/getfsl.sh
sh "$HOME/Downloads/fat_setup/getfsl.sh" "$HOME/fsl"
```

Wait for `FSL successfully installed`. This is a larger download than the FAT
atlas. FSL is installed separately from the `fat` Conda environment. The command
above uses `~/fsl`; use your actual installation directory below if different.
[Official Linux guide](https://fsl.fmrib.ox.ac.uk/fsl/docs/install/linux.html),
[official macOS guide](https://fsl.fmrib.ox.ac.uk/fsl/docs/install/macos.html)

Set up FSL for the current terminal, then reactivate `fat`:

```bash
export FSLDIR="$HOME/fsl"
source "$FSLDIR/etc/fslconf/fsl.sh"
conda activate fat
```

For a **new terminal session**, load your Conda shell setup, then run the three
lines above again. For the Miniforge installation in step 1, the shell setup is:

```bash
source "$HOME/miniforge3/etc/profile.d/conda.sh"
```

With an existing Miniconda/Anaconda installation, use its shell setup instead.
There is no need to reinstall the packages for another subject.

### 5. Download the workflow

```bash
mkdir -p "$HOME/code"
cd "$HOME/code"
git clone https://github.com/LucSam/tractseg_xtract_fat.git
cd tractseg_xtract_fat
```

For an existing clone, run `git pull --ff-only` from its directory.
`fat.sh` contains the complete workflow and can also be shared as a single file.

### 6. Install the FAT atlas and template

Run this once, with an internet connection:

```bash
bash fat.sh --setup-atlas
```

This installation command downloads the HCP1065 probability archive and
ICBM2009a template archive (about 77 MB), verifies their SHA-256 checksums,
and prepares the FAT maps and brain template in
`~/.cache/tractseg_xtract_fat/hcp1065`.

For a shared installation or another location:

```bash
bash fat.sh --setup-atlas --atlas-dir /absolute/path/to/atlases/hcp1065
```

Pass the same `--atlas-dir` to subsequent commands. Tracking checks the installed
files and their checksums before starting; it runs offline and leaves the atlas
installation unchanged. Harvard-Oxford and its MNI152 template come from FSL
in step 4.

## How to use

### 7. Prepare the inputs and check the installation

Use FODs from your diffusion preprocessing pipeline and a brain-extracted T1
from the same individual:

```text
subject01/mri/
  wm.nii.gz          # MRtrix white-matter FOD spherical-harmonic coefficients
  t1_brain.nii.gz    # brain-extracted T1
```

`wm.mif` is also accepted. T1 and FOD images can have different grids; the
workflow registers them. FACT uses `peaks.nii.gz` if present, otherwise it
computes three peaks from the FODs.

Set the input path, then check prerequisites and image dimensions:

```bash
IN="/absolute/path/to/subject01/mri"
bash fat.sh --input "$IN" --check
```

Continue after `Prerequisites and inputs OK.`

### 8. Run iFOD2

```bash
OUT="$IN/fat_output"
bash fat.sh --input "$IN" --output "$OUT" > "$IN/fat_run.log" 2>&1
```

Use a new output directory for each run. Progress and errors are written to
`fat_run.log`. The script estimates the registration transforms, prepares the
masks, and tracks 2000 streamlines for each side.

Check completion:

```bash
if [ -f "$OUT/SUCCESS" ]; then
  echo "FAT reconstruction completed."
else
  tail -n 40 "$IN/fat_run.log"
fi
```

`SUCCESS` is written when every requested tract contains the selected number
of complete streamlines within its bundle mask, with endpoints in opposite
cortical end regions.

### 9. Inspect the results

```bash
tckinfo "$OUT/iFOD2_trackings/FAT_left.tck" -count
tckinfo "$OUT/iFOD2_trackings/FAT_right.tck" -count
mrview "$OUT/work/atlas/t1_dwi.nii.gz" \
  -tractography.load "$OUT/iFOD2_trackings/FAT_left.tck" \
  -tractography.load "$OUT/iFOD2_trackings/FAT_right.tck"
```

Add the bundle masks and `_b`/`_e` cortical regions with MRview's Overlay tool
to review registration and trajectories.

| Output | Contents |
| --- | --- |
| `iFOD2_trackings/` | `FAT_left.tck` and `FAT_right.tck`; other algorithms get their own folders |
| `bundle_segmentations/` | Masks used for tracking and containment checks |
| `bundle_segmentations_original/` | Thresholded HCP1065 probability maps |
| `anatomical_rois/` | Registered IFG and SFG/SMA cortex regions |
| `endings_segmentations/` | Cortical end regions with the selected margin |
| `seed_masks/` | End regions intersected with the bundle mask |
| `run.json`, `commands.log` | Effective settings and executed workflow commands |
| `qc_summary.csv`, `roi_qc.csv` | Mask volumes, connectivity and region overlap |
| `work/atlas/` | Registered probabilities, T1 and registration records |
| `SUCCESS` | Completion marker |

## Options

### Select a tracking algorithm

```bash
bash fat.sh --input "$IN" --output "$IN/fat_sd_stream" --algorithm SD_STREAM
```

Select several algorithms with a comma-separated list:

```bash
bash fat.sh --input "$IN" --output "$IN/fat_algorithms" --algorithm iFOD2,SD_STREAM,FACT
```

| Algorithm | Input | Tracking |
| --- | --- | --- |
| `iFOD2` (default) | FODs | Probabilistic |
| `SD_STREAM` | FODs | Deterministic |
| `FACT` | Three FOD peaks | Deterministic |
| `Tensor_Det` | DWI with gradients | Deterministic tensor |
| `Tensor_Prob` | DWI with gradients | Residual-bootstrap tensor |

For tensor tracking, supply a preprocessed DWI `.mif` containing its gradient
table, in the same grid as the FODs. The workflow selects b=0 and the lowest
nonzero shell:

```bash
bash fat.sh --input "$IN" --output "$IN/fat_tensor" \
  --algorithm Tensor_Det,Tensor_Prob \
  --dwi /absolute/path/to/dwi_den_unr_pre_unbia.mif
```

### Set tracking and mask parameters

```bash
bash fat.sh --input "$IN" --output "$IN/fat_5000" \
  --streamlines 5000 --cutoff 0.1 --threads 8
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--streamlines` | `2000` | Final streamlines per side and algorithm |
| `--cutoff` | `0.05` | FOD/peak amplitude cutoff |
| `--tensor-fa` | `0.1` | FA cutoff for tensor tracking |
| `--min-length` | `20` | Minimum streamline length, mm |
| `--max-length` | `150` | Maximum streamline length, mm |
| `--threads` | `4` | CPU threads |
| `--max-seeds` | `2000000` | Maximum seed attempts per side and algorithm |
| `--candidates` | Twice the target; four times for tensors | Candidate tracks before containment and endpoint checks |
| `--mask-threshold` | `0.05` | HCP1065 probability threshold |
| `--mask-margin` | `3` | Bundle mask margin, mm |
| `--roi-margin` | `3` | Cortical end-region margin, mm |

Show all options or preview the commands:

```bash
bash fat.sh --help
bash fat.sh --input "$IN" --output "$IN/fat_preview" --dry-run
```

Registration transform reuse is described in [METHODS.md](METHODS.md).

## FAQ

### Can I use the atlas on a computer without internet access?

Run step 6 on a connected computer, copy the resulting atlas directory to the
other computer, and pass its location with `--atlas-dir`.

### How do I run several subjects?

```bash
for IN in /data/subject*/mri; do
  bash fat.sh --input "$IN" --output "$IN/fat_output" > "$IN/fat_run.log" 2>&1 || break
done
```

### A run stopped. What should I check?

| Message | Action |
| --- | --- |
| Missing command or Python package | Activate the `fat` environment and check the relevant installation step. |
| Missing FSL file | Set `FSLDIR` or `--fsl-dir` to the installation containing Harvard-Oxford and MNI152. |
| Atlas is not installed | Complete step 6 using the same atlas directory. |
| Atlas file missing or checksum mismatch | Repeat `--setup-atlas` to restore the extracted files. |
| Atlas cache checksum mismatch | Remove the archive named in the error, then repeat `--setup-atlas`. |
| Output already exists | Choose a new `--output` directory. |
| Too few valid streamlines | Review the registration, bundle mask and end regions; `--candidates` and `--max-seeds` control the tracking budget. |
| Disconnected mask or missing ROI overlap | Inspect the registered probability map and cortical regions in MRview. |

## Development checks

```bash
conda install -n fat --override-channels -c conda-forge shellcheck ruff mypy
bash tests/verify.sh
```

The checks cover image geometry, atlas integrity, command-line options, mask
containment and endpoint connections, followed by ShellCheck, Ruff and mypy.

## Attribution

**Workflow author: Lucius Fekonja.** Atlas and software methods belong to their
respective authors. Please cite the components used:

- Yeh FC (2022), *Population-based tract-to-region connectome of the human brain
  and its hierarchical topology.* [Nature Communications](https://doi.org/10.1038/s41467-022-32595-4).
  The [HCP1065 atlas](https://brain.labsolver.org/hcp_trk_atlas.html) is CC BY-SA 4.0.
  Derived atlas masks should retain this attribution and license information.
- Atlas data derive from the Human Connectome Project, WU-Minn Consortium;
  [HCP acknowledgment and data terms](https://www.humanconnectome.org/study/hcp-young-adult/document/wu-minn-hcp-consortium-open-access-data-use-terms).
- Fonov and colleagues: [ICBM2009 templates, citations and license](https://www.bic.mni.mcgill.ca/ServicesAtlases/ICBM152NLin2009).
  The download's copyright notice is retained as `ICBM_COPYING.txt` in the cache.
- Harvard-Oxford contributors: [FSL atlas documentation](https://fsl.fmrib.ox.ac.uk/fsl/docs/other/datasets.html).
- Tournier et al. (2019), [MRtrix3](https://doi.org/10.1016/j.neuroimage.2019.116137);
  [ANTs registration](https://github.com/ANTsX/ANTs).
