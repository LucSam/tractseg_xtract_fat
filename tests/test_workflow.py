"""Regression tests use tiny synthetic images and real MRtrix image readers."""

import importlib.util
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

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
        self.save("t1_brain.nii.gz", np.ones((4, 5, 6)))

    def save(self, name: str, data: np.ndarray, shift: float = 0) -> Path:
        path = self.folder / name
        affine = np.eye(4)
        affine[0, 3] = shift
        nib.save(nib.Nifti1Image(data.astype(np.float32), affine), path)
        return path

    def cli(self, *args: str, **env: str) -> subprocess.CompletedProcess:
        environment = os.environ.copy()
        for key in ("OUTPUT_DIR", "ROI_DIR", "DENSITY", "ALGORITHMS", "COMPUTE_FA", "T1", "T1_TO_MNI_PREFIX", "T1_TO_DWI_AFFINE"):
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

    def tensor_input(self, degenerate: bool = False) -> Path:
        directions = np.array([[1, 0, 0], [0, 1, 0], [0, 0, 1],
                               [1, 1, 0], [1, 0, 1], [0, 1, 1]], dtype=float)
        directions /= np.linalg.norm(directions, axis=1, keepdims=True)
        if degenerate:
            directions[:] = [1, 0, 0]
        gradients = np.vstack((np.zeros((1, 4)),
                               np.column_stack((directions, np.full(6, 1500))),
                               np.column_stack((directions, np.full(6, 3000)))))
        table = self.folder / "gradients.txt"
        np.savetxt(table, gradients)
        image = self.save("dwi.nii.gz", np.ones((4, 5, 6, 13)))
        output = self.folder / "dwi.mif"
        subprocess.run(["mrconvert", str(image), str(output), "-grad", str(table), "-quiet"], check=True)
        return output

    def test_tensor_input_selects_lowest_shell_and_preserves_read_only_check(self) -> None:
        dwi = self.tensor_input()
        self.assertAlmostEqual(qc.tensor_shell(dwi, self.fod), 1500)
        result = self.cli("dry-run", str(self.folder), ALGORITHMS="Tensor_Det Tensor_Prob", DWI=str(dwi))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        commands = [shlex.split(line[2:]) for line in result.stdout.splitlines() if line.startswith("+ ")]
        extraction = next(cmd for cmd in commands if cmd[0] == "dwiextract")
        self.assertEqual(extraction[extraction.index("-shells") + 1], "0,1500")
        for cmd in (cmd for cmd in commands if cmd[0] == "tckgen"):
            self.assertEqual(cmd[1], extraction[2])
            self.assertEqual(cmd[cmd.index("-cutoff") + 1], "0.1")
        self.assertFalse((self.folder / "tractseg_xtract_fat_output").exists())

    def test_tensor_input_rejects_missing_gradients(self) -> None:
        result = self.cli("check", str(self.folder), ALGORITHMS="Tensor_Det", DWI=str(self.fod))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("gradient", result.stderr.lower())

    def test_tensor_input_rejects_degenerate_directions(self) -> None:
        with self.assertRaisesRegex(ValueError, "independent tensor directions"):
            qc.tensor_shell(self.tensor_input(degenerate=True), self.fod)

    def test_tensor_input_rejects_grid_mismatch(self) -> None:
        shifted = self.save("shifted_fod.nii.gz", np.ones((4, 5, 6, 45)), shift=5)
        with self.assertRaisesRegex(ValueError, "Grid mismatch"):
            qc.tensor_shell(self.tensor_input(), shifted)

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

    def test_anatomical_endings_preserve_full_cortex_and_separate_seeds(self) -> None:
        mask = np.zeros((9, 9, 30), dtype=np.uint8)
        mask[3:6, 3:6, :] = 1
        atlas = np.zeros_like(mask)
        atlas[:, :, 1:3] = 1
        atlas[:, :, 27:29] = 2
        bundle = self.save("bundle.nii.gz", mask)
        labels = self.save("cortex.nii.gz", atlas)
        qc.anatomical_endings(labels, bundle, "left", self.folder)
        begin = qc.load_nifti(self.folder / "endings_segmentations/FAT_left_b.nii.gz").get_fdata() > 0
        seed = qc.load_nifti(self.folder / "seed_masks/FAT_left_b.nii.gz").get_fdata() > 0
        raw = qc.load_nifti(self.folder / "anatomical_rois/FAT_left_b.nii.gz").get_fdata() > 0
        np.testing.assert_array_equal(raw, atlas == 1)
        np.testing.assert_array_equal(seed, begin & mask.astype(bool))
        self.assertGreater(begin.sum(), seed.sum())
        with self.assertRaisesRegex(ValueError, "already exists"):
            qc.anatomical_endings(labels, bundle, "left", self.folder)

    def test_bundle_preparation_rejects_unrepaired_disconnection(self) -> None:
        mask = np.zeros((3, 3, 30), dtype=np.uint8)
        mask[:, :, :5] = 1
        mask[:, :, 25:] = 1
        path = self.save("disconnected.nii.gz", mask)
        destination = self.folder / "processed.nii.gz"
        with self.assertRaisesRegex(ValueError, "connected"):
            qc.prepare_bundle(path, destination)
        self.assertFalse(destination.exists())

    def test_bundle_preparation_is_bounded_in_physical_space(self) -> None:
        mask = np.zeros((13, 13, 13), dtype=np.uint8)
        mask[4:9, 4:9, 4:9] = 1
        mask[6, 6, 6] = 0
        affine = np.array([[0, -2, 0, 40], [1, 0, 0, -20], [0, 0, 3, 10], [0, 0, 0, 1]])
        source, destination = self.folder / "source.nii.gz", self.folder / "processed.nii.gz"
        nib.save(nib.Nifti1Image(mask, affine), source)
        before = source.read_bytes()
        qc.prepare_bundle(source, destination)
        processed = qc.load_nifti(destination).get_fdata() > 0
        self.assertEqual(source.read_bytes(), before)
        self.assertTrue(processed[mask > 0].all())
        self.assertTrue(processed[6, 6, 6])
        self.assertFalse(processed[:, :4, :].any())
        self.assertFalse(processed[:, :, :4].any())
        self.assertFalse(processed[:3, :, :].any())
        np.testing.assert_allclose(qc.load_nifti(destination).affine, affine)
        with self.assertRaisesRegex(ValueError, "already exists"):
            qc.prepare_bundle(source, destination)

    def test_atlas_labels_use_xml_indices_and_both_sfg_surfaces(self) -> None:
        atlas = np.zeros((41, 5, 5), dtype=np.uint8)
        for x, y, label in [(5, 1, 13), (6, 1, 15), (35, 1, 13), (34, 1, 15),
                            (17, 2, 91), (23, 2, 91), (5, 2, 92), (35, 2, 92)]:
            atlas[x, y, 2] = label
        affine = np.diag([3.0, 1.0, 1.0, 1.0])
        affine[0, 3] = -60
        path = self.folder / "atlas.nii.gz"
        nib.save(nib.Nifti1Image(atlas, affine), path)
        xml = self.folder / "atlas.xml"
        names = [(12, "Inferior Frontal Gyrus, pars opercularis"),
                 (14, "Inferior Frontal Gyrus, pars triangularis"),
                 (90, "Juxtapositional Lobule Cortex (formerly Supplementary Motor Cortex)"),
                 (91, "Superior Frontal Gyrus")]
        xml.write_text('<atlas><data>' + ''.join(
            f'<label index="{i}">{name}</label>' for i, name in names) + '</data></atlas>')
        out = self.folder / "extracted.nii.gz"
        qc.make_atlas_labels(path, xml, out)
        labels = qc.load_nifti(out).get_fdata()
        self.assertEqual(labels[5, 1, 2], 1)
        self.assertEqual(labels[35, 1, 2], 3)
        self.assertEqual(labels[17, 2, 2], 2)
        self.assertEqual(labels[23, 2, 2], 4)
        self.assertEqual(labels[5, 2, 2], 2)
        self.assertEqual(labels[35, 2, 2], 4)

    def test_probability_mask_rejects_percentages_nan_and_empty(self) -> None:
        for value in (50.0, np.nan, -0.1, 0.0):
            with self.subTest(value=value):
                source = self.save("probability.nii.gz", np.full((5, 5, 5), value))
                with self.assertRaises(ValueError):
                    qc.probability_bundle(source, self.folder / "raw.nii.gz", self.folder / "final.nii.gz")
                self.assertFalse((self.folder / "final.nii.gz").exists())

    def test_probability_mask_records_small_islands_and_preserves_main_support(self) -> None:
        data = np.zeros((15, 15, 15))
        data[3:9, 3:9, 3:9] = 0.06
        data[13, 13, 13] = 0.1
        source = self.save("probability.nii.gz", data)
        original, final = self.folder / "raw.nii.gz", self.folder / "final.nii.gz"
        qc.probability_bundle(source, original, final)
        raw = qc.load_nifti(original).get_fdata() > 0
        processed = qc.load_nifti(final).get_fdata() > 0
        self.assertTrue(raw[13, 13, 13])
        self.assertFalse(processed[13, 13, 13])
        self.assertTrue(processed[3:9, 3:9, 3:9].all())
        self.assertEqual(qc.ndi.label(processed)[1], 1)
        main = data.copy() > 0
        main[13, 13, 13] = False
        self.assertTrue((~processed | qc.dilate_mm(main, np.ones(3), 3.0)).all())
        self.assertTrue((self.folder / "final.json").is_file())

    def test_probability_mask_rejects_major_disconnection_before_writing(self) -> None:
        data = np.zeros((15, 15, 15))
        data[1:4, 1:4, 1:4] = 0.1
        data[10:13, 10:13, 10:13] = 0.1
        source = self.save("probability.nii.gz", data)
        with self.assertRaisesRegex(ValueError, "Major disconnected"):
            qc.probability_bundle(source, self.folder / "raw.nii.gz", self.folder / "final.nii.gz")
        self.assertFalse((self.folder / "raw.nii.gz").exists())

    def test_atlas_download_cache_rejects_checksum_mismatch(self) -> None:
        cache = self.folder / "cache.zip"
        cache.write_bytes(b"incorrect download")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            qc.checked_archive(cache, "https://example.invalid/unused", "0" * 64)

    def test_hcp_registration_does_not_reuse_fsl_mni_transform(self) -> None:
        fsl = self.folder / "fsl"
        for relative in ("data/atlases/HarvardOxford/HarvardOxford-cort-maxprob-thr25-1mm.nii.gz",
                         "data/atlases/HarvardOxford-Cortical.xml",
                         "data/standard/MNI152_T1_1mm_brain.nii.gz"):
            path = fsl / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        mni_prefix = str(self.folder / "FSLMNI_")
        for suffix in ("0GenericAffine.mat", "1InverseWarp.nii.gz"):
            Path(mni_prefix + suffix).touch()
        rigid = self.folder / "rigid.mat"
        rigid.touch()
        template = self.folder / "ICBM2009a.nii.gz"
        out = self.folder / "registered"
        commands = []

        def run(command: list[str], **kwargs: object) -> None:
            commands.append(command)
            if command[0] == "antsRegistrationSyNQuick.sh":
                prefix = command[command.index("-o") + 1]
                for suffix in ("0GenericAffine.mat", "1InverseWarp.nii.gz"):
                    Path(prefix + suffix).touch()

        with patch.object(qc, "hcp_resources", return_value=template), \
                patch.object(qc, "make_atlas_labels"), patch.object(qc.subprocess, "run", side_effect=run):
            qc.atlas_to_subject(self.folder / "t1_brain.nii.gz", self.fod, fsl, out,
                                mni_prefix=mni_prefix, dwi_affine=rigid)
        registration = [c for c in commands if c[0] == "antsRegistrationSyNQuick.sh"]
        self.assertEqual(len(registration), 1)
        self.assertEqual(registration[0][registration[0].index("-f") + 1], str(template))
        bundle_warps = [c for c in commands if any("Frontal_Aslant_Tract_" in x for x in c)]
        self.assertEqual(len(bundle_warps), 2)
        for command in bundle_warps:
            self.assertEqual(command[-6:], ["-t", str(rigid), "-t",
                             f"[{out / 'T1toICBM2009a_0GenericAffine.mat'},1]", "-t",
                             str(out / "T1toICBM2009a_1InverseWarp.nii.gz")])
            self.assertEqual(command[command.index("-n") + 1], "Linear")
            self.assertNotIn(mni_prefix + "1InverseWarp.nii.gz", command)

    def test_anatomical_endings_reject_empty_overlap_before_writing(self) -> None:
        atlas = np.zeros((20, 5, 30), dtype=np.uint8)
        atlas[:2, :, :3] = 1
        atlas[:2, :, 27:] = 2
        mask = np.zeros_like(atlas)
        mask[15:, :, :] = 1
        labels, bundle = self.save("atlas.nii.gz", atlas), self.save("bundle.nii.gz", mask)
        with self.assertRaisesRegex(ValueError, "does not reach"):
            qc.anatomical_endings(labels, bundle, "left", self.folder)
        self.assertFalse((self.folder / "endings_segmentations").exists())

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
        self.assertIn("probability-bundle", result.stdout)
        self.assertNotIn("+ TractSeg ", result.stdout)
        self.assertNotIn("--output_type TOM", result.stdout)
        self.assertIn("FAT_right.tck", result.stdout)

    def test_existing_output_is_protected(self) -> None:
        result = self.cli("segment", str(self.folder), OUTPUT_DIR=str(self.folder))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Output already exists", result.stderr)

    def test_system_bash_allows_automatic_registration_without_cached_transforms(self) -> None:
        environment = os.environ.copy()
        environment.update(T1_TO_MNI_PREFIX="", T1_TO_DWI_AFFINE="", ROI_DIR="", ALGORITHMS="iFOD2")
        result = subprocess.run(
            ["/bin/bash", str(ROOT / "tractseg_xtract_fat.sh"), "dry-run", str(self.folder)],
            env=environment, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("atlas-to-subject", result.stdout)
        self.assertNotIn("--mni-prefix", result.stdout)
        self.assertNotIn("--dwi-affine", result.stdout)

    def test_mif_fod_is_converted_for_anatomical_registration(self) -> None:
        mif = self.folder / "wm.mif"
        subprocess.run(["mrconvert", str(self.fod), str(mif), "-quiet"], check=True)
        self.fod.unlink()
        result = self.cli("dry-run", str(self.folder))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        commands = [shlex.split(line[2:]) for line in result.stdout.splitlines() if line.startswith("+ ")]
        registration = next(cmd for cmd in commands if "atlas-to-subject" in cmd)
        reference = registration[registration.index("--reference") + 1]
        conversion = next(cmd for cmd in commands if cmd[0] == "mrconvert" and reference in cmd)
        self.assertEqual(conversion[1], str(mif))
        self.assertIn("-coord", conversion)
        self.assertTrue(reference.endswith(".nii.gz"))

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
            self.assertNotIn("-stop", cmd, "Allow propagation beyond the first ROI contact.")
            self.assertNotIn("-seed_unidirectional", cmd, "Grow both halves from an interior seed.")
        filters = [cmd for cmd in commands if "filter-tracks" in cmd]
        self.assertEqual(len(filters), len(generators))
        for cmd in filters:
            self.assertIn("--endings", cmd)
        simple = (ROOT / "fat_simple.sh").read_text().split("# Embedded Python helper.", 1)[0]
        generators = [shlex.split(line.strip()) for line in simple.splitlines() if line.strip().startswith("tckgen ")]
        self.assertEqual(len(generators), 6)
        for cmd in generators:
            self.assertEqual(cmd.count("-include"), 2)
            self.assertEqual(cmd.count("-mask"), 1)
            self.assertNotIn("-seed_unidirectional", cmd)
            self.assertNotIn("-stop", cmd)

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
        labels = np.zeros((3, 3, 20))
        labels[:, :, :3] = 1
        labels[:, :, 17:] = 2
        atlas = self.save("native_atlas.nii.gz", labels)
        begin = self.folder / "endings_segmentations/FAT_left_b.nii.gz"
        end = self.folder / "endings_segmentations/FAT_left_e.nii.gz"
        command = ["bash", "-c", 'source "$1"; shift; fat_qc "$@"', "test", str(script)]
        result = subprocess.run(command + ["endings", str(atlas), str(mask), "left", str(self.folder)],
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
