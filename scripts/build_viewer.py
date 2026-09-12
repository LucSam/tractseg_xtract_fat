"""Export a lightweight display subset from checked TCK files for GitHub Pages.

Development only: requires plotly and scikit-image in addition to the workflow packages.
Usage: python3 scripts/build_viewer.py --fod-results RESULTS --extra-results RESULTS
"""

import argparse
import json
from pathlib import Path

import nibabel as nib
import numpy as np
from plotly.offline import get_plotlyjs
from scipy.ndimage import gaussian_filter
from skimage.measure import marching_cubes

from fat_qc import check_tracks, load_nifti, same_grid


def mesh(path: Path) -> dict:
    img = load_nifti(path)
    field = gaussian_filter((np.asanyarray(img.dataobj) > 0).astype(np.float32), 0.8)
    vertices, faces, _, _ = marching_cubes(field, 0.5, step_size=3)
    vertices = nib.affines.apply_affine(img.affine, vertices).round(2)
    return dict(type="mesh3d", x=vertices[:, 0].tolist(), y=vertices[:, 1].tolist(),
                z=vertices[:, 2].tolist(), i=faces[:, 0].tolist(), j=faces[:, 1].tolist(),
                k=faces[:, 2].tolist(), color="#c7ced6", opacity=0.08,
                hoverinfo="skip", showscale=False, showlegend=False, name="Brain")


def tracks(path: Path, side: str) -> dict:
    streamlines = nib.streamlines.load(path).streamlines
    coordinates: list = []
    colors = []
    # A fixed quarter for display only; source trajectories remain untouched.
    for streamline in streamlines[::4]:
        step = max(1, int(np.ceil(len(streamline) / 120)))
        indices = np.unique(np.r_[np.arange(0, len(streamline), step), len(streamline) - 1])
        points = streamline[indices]
        rgb = np.abs(np.gradient(points, axis=0))
        rgb /= np.maximum(np.linalg.norm(rgb, axis=1, keepdims=True), 1e-12)
        rgb = np.rint(255 * rgb).astype(int)
        coordinates.extend(points.round(2).astype(float).tolist())
        coordinates.append([None, None, None])
        colors.extend([f"rgb({r},{g},{b})" for r, g, b in rgb])
        colors.append("rgb(0,0,0)")
    # Convert float32 rounding artefacts to compact decimal JSON.
    coordinates = [[round(v, 2) if v is not None else None for v in point] for point in coordinates]
    return dict(type="scatter3d", x=[v[0] for v in coordinates], y=[v[1] for v in coordinates],
                z=[v[2] for v in coordinates], mode="lines", name=side,
                line=dict(color=colors, width=3), hoverinfo="skip", connectgaps=False,
                showlegend=False)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fod-results", type=Path, required=True)
    parser.add_argument("--extra-results", type=Path, required=True)
    parser.add_argument("--out", type=Path, default=Path("docs"))
    args = parser.parse_args()
    data_dir = args.out / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    vendor = args.out / "vendor"
    vendor.mkdir(exist_ok=True)
    (vendor / "plotly.min.js").write_text(get_plotlyjs())
    (args.out / ".nojekyll").touch()
    brain = mesh(args.fod_results / "work/atlas/t1_dwi.nii.gz")
    (data_dir / "brain.json").write_text(json.dumps(brain, separators=(",", ":")))
    algorithms = ["iFOD2", "SD_STREAM", "FACT", "Tensor_Det", "Tensor_Prob"]
    for algorithm in algorithms:
        folder = args.fod_results if algorithm in algorithms[:2] else args.extra_results
        if not (folder / "SUCCESS").is_file():
            raise ValueError(f"Missing completed-run marker: {folder}")
        traces = []
        for side in ("left", "right"):
            name = f"FAT_{side}"
            mask = folder / f"bundle_segmentations/{name}.nii.gz"
            original_mask = args.fod_results / f"bundle_segmentations/{name}.nii.gz"
            same_grid(original_mask, mask)
            if not np.array_equal(load_nifti(mask).get_fdata(), load_nifti(original_mask).get_fdata()):
                raise ValueError(f"Comparison mask changed: {mask}")
            endings = tuple(folder / f"endings_segmentations/{name}_{end}.nii.gz" for end in ("b", "e"))
            path = folder / f"{algorithm}_trackings/{name}.tck"
            check_tracks(path, 2000, mask, endings)
            traces.append(tracks(path, side))
        (data_dir / f"{algorithm}.json").write_text(json.dumps(traces, separators=(",", ":")))
    (data_dir / "manifest.json").write_text(json.dumps(dict(
        algorithms=algorithms, streamlines_per_side=2000, displayed_per_side=500,
        colours="Absolute RAS tangent: red left-right, green anterior-posterior, blue inferior-superior",
        source="HCP1065 FAT workflow example; Lucius Fekonja",
    ), indent=2) + "\n")


if __name__ == "__main__":
    main()
