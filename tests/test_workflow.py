"""Regression tests use tiny synthetic images and real MRtrix image readers."""

import importlib.util
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

import nibabel as nib
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("fat_qc", ROOT / "scripts/fat_qc.py")
assert SPEC is not None and SPEC.loader is not None
qc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(qc)


class WorkflowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="fat test ")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.peaks = self.save("peaks.nii.gz", np.ones((4, 5, 6, 9)))
        self.fod = self.save("wm.nii.gz", np.ones((4, 5, 6, 45)))

    def save(self, name: str, data: np.ndarray, shift: float = 0) -> Path:
        path = self.folder / name
        affine = np.eye(4)
        affine[0, 3] = shift
        nib.save(nib.Nifti1Image(data.astype(np.float32), affine), path)
        return path

    def cli(self, *args: str, **env: str) -> subprocess.CompletedProcess:
        environment = os.environ.copy()
        for key in ("OUTPUT_DIR", "ROI_DIR", "DENSITY", "ALGORITHMS", "COMPUTE_FA"):
            environment.pop(key, None)
        environment.update(env)
        return subprocess.run(
            ["bash", str(ROOT / "tractseg_xtract_fat.sh"), *args],
            text=True, capture_output=True, env=environment,
        )

    def test_input_grid_passes(self) -> None:
        mask = self.save("mask.nii.gz", np.ones((4, 5, 6)))
        qc.validate_inputs(self.peaks, self.fod, [mask])

    def test_rejects_affine_mismatch(self) -> None:
        mask = self.save("shifted.nii.gz", np.ones((4, 5, 6)), shift=10)
        with self.assertRaisesRegex(ValueError, "Grid mismatch"):
            qc.validate_inputs(self.peaks, self.fod, [mask])

    def test_rejects_scalar_as_fod(self) -> None:
        mask = self.save("scalar.nii.gz", np.ones((4, 5, 6)))
        with self.assertRaisesRegex(ValueError, "SH coefficients"):
            qc.validate_inputs(self.peaks, mask, [])

    def test_rejects_wrong_peak_components(self) -> None:
        peaks = self.save("bad.nii.gz", np.ones((4, 5, 6, 6)))
        with self.assertRaisesRegex(ValueError, "9 volumes"):
            qc.validate_inputs(peaks, None, [])

    def test_missing_peak_triplet_becomes_zero(self) -> None:
        data = np.ones((4, 5, 6, 9))
        data[0, 0, 0, 3:6] = np.nan
        clean = qc.clean_peaks(data)
        np.testing.assert_array_equal(clean[0, 0, 0], [1, 1, 1, 0, 0, 0, 1, 1, 1])
        self.assertTrue(np.isnan(data[0, 0, 0, 3]))

    def test_partial_nan_or_inf_rejected(self) -> None:
        for value in (np.nan, np.inf):
            with self.subTest(value=value):
                data = np.ones((4, 5, 6, 9))
                data[0, 0, 0, 0] = value
                with self.assertRaisesRegex(ValueError, "Inf or partially NaN"):
                    qc.clean_peaks(data)

    def test_empty_segmentation_rejected(self) -> None:
        mask = self.save("empty.nii.gz", np.zeros((4, 5, 6)))
        with self.assertRaisesRegex(ValueError, "Empty FAT"):
            qc.export_mask(mask, self.peaks, self.folder / "result.nii.gz")

    def test_probability_map_not_mistaken_for_binary(self) -> None:
        mask = self.save("prob.nii.gz", np.full((4, 5, 6), 0.5))
        with self.assertRaisesRegex(ValueError, "Invalid binary"):
            qc.export_mask(mask, self.peaks, self.folder / "result.nii.gz")

    def test_missing_backend_output_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "Missing input"):
            qc.export_mask(self.folder / "absent.nii.gz", self.peaks, self.folder / "result.nii.gz")

    def test_streamline_shortfall_rejected(self) -> None:
        path = self.folder / "short.tck"
        tractogram = nib.streamlines.Tractogram(
            [np.array([[0, 0, 0], [0, 0, 3]])], affine_to_rasmm=np.eye(4)
        )
        nib.streamlines.save(tractogram, str(path))
        qc.check_tracks(path, 1)
        with self.assertRaisesRegex(ValueError, "1/2 streamlines"):
            qc.check_tracks(path, 2)

    def test_endings_follow_world_geometry_and_stay_in_mask(self) -> None:
        mask = np.zeros((5, 5, 30), dtype=np.uint8)
        mask[1:4, 1:4, 1:29] = 1
        path = self.folder / "elongated.nii.gz"
        affine = np.array([[1.5, 0, 0, -40], [0, -1.5, 0, 20], [0, 0, -2, 80], [0, 0, 0, 1]])
        nib.save(nib.Nifti1Image(mask, affine), path)
        begin, end = self.folder / "begin.nii.gz", self.folder / "end.nii.gz"
        qc.derive_endings(path, begin, end)
        a, b = np.asarray(qc.load_nifti(begin).dataobj) > 0, np.asarray(qc.load_nifti(end).dataobj) > 0
        self.assertTrue(a.any() and b.any())
        self.assertFalse((a & b).any())
        self.assertTrue(np.all(mask[a | b]))
        self.assertLess(nib.affines.apply_affine(affine, np.argwhere(a))[:, 2].mean(),
                        nib.affines.apply_affine(affine, np.argwhere(b))[:, 2].mean())

    def test_endings_reject_disconnected_mask(self) -> None:
        mask = np.ones((3, 3, 30), dtype=np.uint8)
        mask[:, :, 15] = 0
        path = self.save("disconnected.nii.gz", mask)
        with self.assertRaisesRegex(ValueError, "connected"):
            qc.derive_endings(path, self.folder / "a.nii.gz", self.folder / "b.nii.gz")

    def test_endpoint_filter_rejects_fragments_and_wrong_endpoints(self) -> None:
        mask = np.ones((3, 3, 20), dtype=np.uint8)
        path = self.save("bundle.nii.gz", mask)
        a, b = np.zeros_like(mask), np.zeros_like(mask)
        a[:, :, :3] = 1
        b[:, :, 17:] = 1
        begin, end = self.save("a.nii.gz", a), self.save("b.nii.gz", b)
        good = np.array([[1, 1, 1], [1, 1, 10], [1, 1, 18]])
        fragment = np.array([[1, 1, 1], [1, 1, 10]])
        visits_but_ends_wrong = np.array([[1, 1, 5], [1, 1, 1], [1, 1, 18], [1, 1, 5]])
        source, out = self.folder / "all.tck", self.folder / "connected.tck"
        nib.streamlines.save(nib.streamlines.Tractogram(
            [fragment, visits_but_ends_wrong, good, good[::-1]], affine_to_rasmm=np.eye(4)
        ), str(source))
        qc.filter_tracks(source, path, out, 2, (begin, end))
        qc.check_tracks(out, 2, path, (begin, end))
        with self.assertRaisesRegex(ValueError, "end regions"):
            qc.check_tracks(source, 4, path, (begin, end))
        with self.assertRaisesRegex(ValueError, "Only 2/3"):
            qc.filter_tracks(source, path, self.folder / "short.tck", 3, (begin, end))
        self.assertFalse((self.folder / "short.tck").exists())

    def test_end_regions_cannot_overlap(self) -> None:
        mask = self.save("bundle.nii.gz", np.ones((3, 3, 20)))
        source = self.folder / "source.tck"
        nib.streamlines.save(nib.streamlines.Tractogram(
            [np.array([[1, 1, 1], [1, 1, 18]])], affine_to_rasmm=np.eye(4)
        ), str(source))
        with self.assertRaisesRegex(ValueError, "overlap"):
            qc.check_tracks(source, 1, mask, (mask, mask))

    def test_inside_mask_rejects_outside_vertex(self) -> None:
        mask = np.ones((4, 5, 6), dtype=bool)
        self.assertFalse(qc.inside_mask(np.array([[0, 0, 0], [-0.6, 0, 0]]), mask))
        self.assertTrue(qc.inside_mask(np.array([[0, 0, 0], [3, 4, 5]]), mask))

    def test_inside_mask_checks_between_valid_vertices(self) -> None:
        mask = np.ones((4, 5, 6), dtype=bool)
        mask[1, 1, 1] = False
        self.assertFalse(qc.inside_mask(np.array([[0, 1, 1], [3, 1, 1]]), mask))

    def test_tiny_corner_crossing_is_not_missed(self) -> None:
        mask = np.ones((4, 5, 6), dtype=bool)
        mask[1, 0, 0] = False
        # Only a very short portion between x=0.5 and y=0.5 enters the bad cell.
        self.assertFalse(qc.inside_mask(np.array([[0, 0, 0], [1, 0.9999, 0]]), mask))
        self.assertTrue(qc.inside_mask(np.array([[0, 0, 0], [1, 1, 0]]), mask))

    def test_filter_preserves_whole_tracks_in_oblique_world_space(self) -> None:
        mask_path = self.folder / "oblique.nii.gz"
        affine = np.array([[0, -2, 0, 20], [1.5, 0, 0, -30], [0, 0, 3, 10], [0, 0, 0, 1]])
        mask = np.ones((4, 5, 6), dtype=np.uint8)
        mask[1, 1, 1] = 0
        nib.save(nib.Nifti1Image(mask, affine), mask_path)
        good = nib.affines.apply_affine(affine, np.array([[0, 0, 0], [2, 0, 0], [3, 0, 0]]))
        bad = nib.affines.apply_affine(affine, np.array([[0, 1, 1], [3, 1, 1]]))
        source, destination = self.folder / "candidates.tck", self.folder / "filtered.tck"
        nib.streamlines.save(nib.streamlines.Tractogram([bad, good], affine_to_rasmm=np.eye(4)), str(source))
        with self.assertRaisesRegex(ValueError, "leave the bundle mask"):
            qc.check_tracks(source, 2, mask_path)
        qc.filter_tracks(source, mask_path, destination, 1)
        qc.check_tracks(destination, 1, mask_path)
        saved = list(nib.streamlines.load(str(destination)).streamlines)
        np.testing.assert_allclose(saved[0], good)
        missing = self.folder / "insufficient.tck"
        with self.assertRaisesRegex(ValueError, "Only 1/2"):
            qc.filter_tracks(source, mask_path, missing, 2)
        self.assertFalse(missing.exists())

    def test_dry_run_with_spaces_is_read_only(self) -> None:
        out = self.folder / "not created"
        result = self.cli("dry-run", str(self.folder), OUTPUT_DIR=str(out))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(out.exists())
        self.assertIn("--tract_definition xtract", result.stdout)
        self.assertNotIn("--output_type TOM", result.stdout)
        self.assertIn("FAT_right.tck", result.stdout)

    def test_existing_output_is_protected(self) -> None:
        result = self.cli("segment", str(self.folder), OUTPUT_DIR=str(self.folder))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Output already exists", result.stderr)

    def test_tracking_uses_only_the_bundle_mask(self) -> None:
        self.save("mask.nii.gz", np.ones((4, 5, 6)))
        result = self.cli("dry-run", str(self.folder))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        commands = [shlex.split(line[2:]) for line in result.stdout.splitlines() if line.startswith("+ tckgen ")]
        self.assertEqual(len(commands), 6)
        for command in commands:
            self.assertEqual(command.count("-mask"), 1, "Multiple MRtrix masks form a UNION.")
            self.assertIn("bundle_segmentations", command[command.index("-mask") + 1])

    def test_pipeline_requires_opposite_end_regions(self) -> None:
        result = self.cli("dry-run", str(self.folder))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        commands = [shlex.split(line[2:]) for line in result.stdout.splitlines() if line.startswith("+ ")]
        generators = [cmd for cmd in commands if cmd[0] == "tckgen"]
        for cmd in generators:
            self.assertEqual(cmd.count("-include"), 2)
            self.assertIn("-stop", cmd)
        filters = [cmd for cmd in commands if "filter-tracks" in cmd]
        self.assertEqual(len(filters), len(generators))
        for cmd in filters:
            self.assertIn("--endings", cmd)
        simple = (ROOT / "fat_simple.sh").read_text().split("# Embedded Python helper.", 1)[0]
        generators = [shlex.split(line.strip()) for line in simple.splitlines() if line.strip().startswith("tckgen ")]
        self.assertEqual(len(generators), 4)
        for cmd in generators:
            self.assertEqual(cmd.count("-include"), 2)
            self.assertEqual(cmd.count("-mask"), 1)
            self.assertIn("-seed_unidirectional", cmd)
            self.assertIn("-stop", cmd)

    def test_bad_tracking_parameters_rejected(self) -> None:
        result = self.cli("check", str(self.folder), MIN_LENGTH="200", MAX_LENGTH="100")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MIN_LENGTH", result.stderr)

    def test_batch_output_override_rejected(self) -> None:
        result = self.cli("check", str(self.folder), str(self.folder), OUTPUT_DIR=str(self.folder / "out"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("one input directory", result.stderr)

    def test_simple_script_works_without_external_helper(self) -> None:
        standalone = self.folder / "standalone"
        standalone.mkdir()
        script = standalone / "fat_simple.sh"
        shutil.copyfile(ROOT / "fat_simple.sh", script)
        environment = os.environ.copy()
        environment.update(IN=str(self.folder), OUT=str(standalone / "output"))
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; fat_qc inputs --peaks "$2" --fod "$3"',
             "standalone-test", str(script), str(self.peaks), str(self.fod)],
            cwd=standalone, env=environment, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Input dimensions and grids OK", result.stdout)
        self.assertFalse((standalone / "scripts").exists())
        self.assertFalse((standalone / "output").exists())
        mask = self.save("standalone_mask.nii.gz", np.ones((4, 5, 6)))
        source, destination = self.folder / "source.tck", standalone / "filtered.tck"
        nib.streamlines.save(nib.streamlines.Tractogram(
            [np.array([[0, 0, 0], [0, 0, 3]])], affine_to_rasmm=np.eye(4)
        ), str(source))
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; shift; fat_qc "$@"',
             "standalone-test", str(script), "filter-tracks", str(source), str(mask),
             str(destination), "1"],
            cwd=standalone, env=environment, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        qc.check_tracks(destination, 1, mask)

    def test_embedded_helper_matches_the_verified_module(self) -> None:
        script = (ROOT / "fat_simple.sh").read_text()
        embedded = script.split("<<'FAT_QC_PY'\n", 1)[1].split("\nFAT_QC_PY\n", 1)[0]
        self.assertEqual(embedded, (ROOT / "scripts/fat_qc.py").read_text().rstrip("\n"))

    def test_standalone_cli_derives_and_checks_end_regions(self) -> None:
        script = self.folder / "fat_simple.sh"
        shutil.copyfile(ROOT / "fat_simple.sh", script)
        mask = self.save("long_mask.nii.gz", np.ones((3, 3, 20)))
        begin, end = self.folder / "begin.nii.gz", self.folder / "end.nii.gz"
        command = ["bash", "-c", 'source "$1"; shift; fat_qc "$@"', "test", str(script)]
        result = subprocess.run(command + ["endings", str(mask), str(begin), str(end)],
                                cwd=self.folder, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        source, out = self.folder / "input.tck", self.folder / "output.tck"
        nib.streamlines.save(nib.streamlines.Tractogram(
            [np.array([[1, 1, 1], [1, 1, 18]])], affine_to_rasmm=np.eye(4)
        ), str(source))
        result = subprocess.run(command + ["filter-tracks", str(source), str(mask), str(out), "1",
                                          "--endings", str(begin), str(end)],
                                cwd=self.folder, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        qc.check_tracks(out, 1, mask, (begin, end))


if __name__ == "__main__":
    unittest.main()
