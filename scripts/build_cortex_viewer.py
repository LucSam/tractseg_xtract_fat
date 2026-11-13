"""Export FastSurfer pial contours for the public viewer and a local HTML preview.

Requires ANTsPy, NiBabel, NumPy, pandas, PyVista and Matplotlib. Reconstruction
must already be complete; this only transforms and exports the existing mesh.
"""

from pathlib import Path
import argparse
import json
import os
import re
import time


def write_local_preview(webroot: Path, destination: Path) -> None:
    """Bundle the public viewer unchanged so it also works from a file:// URL."""
    template = (webroot / "index.html").read_text()
    scripts = re.findall(r'<script defer src="([^"]+)"></script>', template)
    template = re.sub(r'<script defer src="[^"]+"></script>', "", template)
    template = re.sub(r'<link rel="stylesheet" href="([^"]+)">',
                      lambda match: "<style>" + (webroot / match[1].split("?")[0]).read_text() + "</style>", template)
    manifest = json.loads((webroot / "data/manifest.json").read_text())
    data = {name: json.loads((webroot / "data" / f"{name}.json").read_text())
            for name in ["cortex", *manifest["algorithms"]]}
    code = ["window.FAT_VIEWER_DATA=" + json.dumps(data, separators=(",", ":")) + ";"]
    code.extend((webroot / name.split("?")[0]).read_text() for name in scripts)
    bundled = "\n".join("<script>" + source.replace("</script", "<\\/script") + "</script>" for source in code)
    destination.write_text(template.replace("</body>", bundled + "\n</body>"))


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--subject", type=Path, default=root / "results/fastsurfer/subjects/fat_example")
    parser.add_argument("--registration", type=Path, default=root / "results/hcp1065_fat/work/atlas/registration.json")
    parser.add_argument("--t1", type=Path, default=root / "mri/t1_brain.nii.gz")
    parser.add_argument("--webroot", type=Path, default=root / "docs")
    parser.add_argument("--out", type=Path, default=root / "results/fastsurfer")
    args = parser.parse_args()
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    os.environ["MPLCONFIGDIR"] = str(out / ".cache/matplotlib")

    import ants
    import nibabel as nib
    from nibabel.freesurfer.mghformat import MGHHeader, MGHImage
    import numpy as np
    import pandas as pd
    import pyvista as pv

    start = time.monotonic()
    subject = args.subject
    volume = nib.load(subject / "mri/orig.mgz")
    assert isinstance(volume, MGHImage), "Expected a FreeSurfer MGH volume"
    header = volume.header
    assert isinstance(header, MGHHeader), "Expected FreeSurfer tkregister geometry"
    # FreeSurfer vertices are in tkregister RAS. orig.mgz supplies the conversion
    # to scanner RAS, which is the coordinate system of the original full-head T1.
    surface_to_scanner = volume.affine @ np.linalg.inv(header.get_vox2ras_tkr())
    registration = json.loads(args.registration.read_text())
    transform = registration["t1_to_dwi_affine"]
    surfaces = []
    scanner_surfaces = []
    reports = []
    for hemisphere in ["lh", "rh"]:
        vertices, faces = nib.freesurfer.read_geometry(subject / f"surf/{hemisphere}.pial")
        scanner_ras = nib.affines.apply_affine(surface_to_scanner, vertices)
        scanner_surfaces.append(pv.PolyData(scanner_ras, np.c_[np.full(len(faces), 3), faces].ravel()))
        # ANTs points use LPS and the inverse direction of image resampling.
        points = pd.DataFrame(scanner_ras * [-1, -1, 1], columns=["x", "y", "z"])
        transformed = ants.apply_transforms_to_points(3, points, [transform], whichtoinvert=[True])
        dwi_ras = transformed[["x", "y", "z"]].to_numpy() * [-1, -1, 1]
        inverse = ants.apply_transforms_to_points(3, transformed.iloc[::100], [transform], whichtoinvert=[False])
        error = np.linalg.norm(inverse[["x", "y", "z"]].to_numpy() - points.iloc[::100].to_numpy(), axis=1)
        assert error.max() < 0.001, "Surface transform does not invert correctly"
        surface = pv.PolyData(dwi_ras, np.c_[np.full(len(faces), 3), faces].ravel())
        original_open_edges = surface.n_open_edges
        assert original_open_edges == 0, f"{hemisphere} pial surface has an open boundary"
        # Preserve the reconstructed topology. VTK simplification introduced
        # non-manifold edges in this subject's left pial surface.
        surface = surface.compute_normals(consistent_normals=True, auto_orient_normals=True, split_vertices=False)
        assert np.isfinite(surface.points).all()
        assert surface.n_open_edges == 0, f"{hemisphere} display mesh has an open boundary"
        reports.append(dict(hemisphere=hemisphere, original_vertices=len(vertices), original_faces=len(faces),
                            display_vertices=surface.n_points, display_faces=surface.n_cells,
                            original_open_edges=original_open_edges, display_open_edges=surface.n_open_edges,
                            original_euler_characteristic=int(len(vertices) - len(faces) / 2),
                            display_euler_characteristic=int(surface.n_points - surface.n_cells / 2),
                            roundtrip_max_error_mm=float(error.max()), bounds=list(surface.bounds)))
        surfaces.append(surface)

    combined = surfaces[0].merge(surfaces[1], merge_points=False)
    combined.save(out / "pial_dwi.vtp")
    vertices = combined.points.round(3)
    faces = combined.faces.reshape(-1, 4)[:, 1:]
    surface_data = dict(x=vertices[:, 0].tolist(), y=vertices[:, 1].tolist(), z=vertices[:, 2].tolist(),
                        i=faces[:, 0].tolist(), j=faces[:, 1].tolist(), k=faces[:, 2].tolist())
    report = dict(source="FastSurfer reconstructed pial surfaces",
                  conformed_voxel_size_mm=[float(value) for value in header.get_zooms()[:3]],
                  tkr_to_scanner_ras=surface_to_scanner.tolist(),
                  t1_to_dwi_affine=transform, hemispheres=reports, additional_smoothing=False,
                  display_simplification=False,
                  vertices=combined.n_points, faces=combined.n_cells, seconds=time.monotonic() - start)
    (out / "surface_provenance.json").write_text(json.dumps(report, indent=2) + "\n")

    data_dir = args.webroot / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    (data_dir / "cortex.json").write_text(json.dumps(surface_data, separators=(",", ":")))
    write_local_preview(args.webroot, out / "tract_preview.html")
    print(json.dumps(report, indent=2), flush=True)

    # Inspect the pial boundaries on axial sections of the same native T1.
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    t1 = nib.as_closest_canonical(nib.load(args.t1))
    image = t1.get_fdata()
    vmax = np.percentile(image[image > 0], 99)
    surfaces_voxel = []
    for surface in scanner_surfaces:
        surface.points = nib.affines.apply_affine(np.linalg.inv(t1.affine), surface.points)
        surfaces_voxel.append(surface)
    fig, axes = plt.subplots(1, 3, figsize=(13, 5), facecolor="#11141a")
    assert isinstance(axes, np.ndarray)
    for ax, fraction in zip(axes, [.42, .59, .70]):
        z = round((image.shape[2] - 1) * fraction)
        ax.imshow(image[:, :, z].T, origin="lower", cmap="gray", vmin=0, vmax=vmax)
        for surface, color in zip(surfaces_voxel, ["#6ce7bb", "#f3c16d"]):
            cut = surface.slice(normal=(0, 0, 1), origin=(0, 0, z))
            offset = 0
            while offset < len(cut.lines):
                size = cut.lines[offset]
                line = cut.points[cut.lines[offset + 1:offset + 1 + size]]
                ax.plot(line[:, 0], line[:, 1], color=color, linewidth=.5)
                offset += int(size) + 1
        ax.axis("off")
    fig.suptitle("FastSurfer pial boundaries on the native T1", color="white")
    fig.tight_layout()
    fig.savefig(out / "pial_alignment_review.png", dpi=130, facecolor=fig.get_facecolor())
    plt.close(fig)


if __name__ == "__main__":
    main()
