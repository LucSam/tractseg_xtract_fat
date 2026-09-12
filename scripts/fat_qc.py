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


def hcp_resources(folder: Path) -> Path:
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
    return brain


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
    icbm_template = hcp_resources(atlas_dir)
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
        "Bundle prior: HCP1065 population probability coverage, registered via subject T1 using ICBM2009a.\n"
        "No training, TractSeg inference, or intersection with an XTRACT mask in the default workflow.\n"
        "Native probability images: work/atlas/FAT_*_probability.nii.gz.\n"
        "Threshold 0.05 is a workflow default, not a clinically validated FAT boundary.\n"
        "Raw threshold masks: bundle_segmentations_original; processed masks: bundle_segmentations.\n"
        "Keep the largest face-connected component only if it contains at least 95% of threshold voxels.\n"
        "Mask processing: 3 mm bounded margin, Gaussian sigma 1 mm, threshold 0.5; preserve the retained component.\n"
        "Cavity filling is limited to that margin; disconnected processed masks fail.\n"
        "Tracking: MRtrix with ONE processed bundle mask.\n"
        "Default FOD/peak cutoff 0.05; tensor FA cutoff 0.1 (b0 plus lowest nonzero DWI shell).\n"
        "Whole streamlines leaving the mask are rejected; all vertices AND connecting segments are checked.\n"
        "Track in both directions from each seed, without stopping at the first complete set of ROI contacts.\n"
        "Tracking requires both endpoints in opposite end regions, in addition to whole-polyline containment.\n"
        "Cortical priors: Harvard-Oxford maxprob thr25 IFG pars opercularis/triangularis and SFG plus SMA.\n"
        "Cortex uses a separate FSL MNI152 registration; do not interchange its warp with ICBM2009a.\n"
        "Atlas labels are warped via subject T1 to DWI, then dilated 3 mm; inspect registration individually.\n"
        "Full cortex labels: anatomical_rois; expanded endpoints: endings_segmentations; mask intersections: seed_masks.\n"
        "Population cortical labels approximate anatomical targets; they are not individual functional maps.\n"
        "No learned FAT endings or TOMs. Insufficient valid connections cause failure, not a partial final bundle.\n"
        "Mean FA CSVs: one mean per streamline, NOT spatially corresponding along-tract profiles.\n"
        "Optional XTRACT dm_regression is a separate comparison, not the HCP1065 tracking mask.\n"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    parameters = sub.add_parser("parameters")
    parameters.add_argument("minimum", type=float)
    parameters.add_argument("maximum", type=float)
    parameters.add_argument("cutoff", type=float)
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
    if args.command == "parameters":
        if not all(math.isfinite(x) for x in (args.minimum, args.maximum, args.cutoff)):
            raise ValueError("Tracking parameters must be finite.")
        if not 0 < args.minimum < args.maximum or args.cutoff <= 0:
            raise ValueError("Require 0 < MIN_LENGTH < MAX_LENGTH and CUTOFF > 0.")
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
