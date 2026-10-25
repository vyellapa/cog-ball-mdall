#!/usr/bin/env python3
"""Local CLI regressions; no containers or reference downloads needed.

Run: python3 -m unittest discover -s test -p 'test_cli.py' -v
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
CLASSIFIED_EXTS = ("mdall.json", "mdall.tsv", "predictions.tsv", "vst.tsv.gz")


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="cog-run-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        mock_bin = self.root / "bin"
        mock_bin.mkdir()
        docker = mock_bin / "docker"
        shutil.copyfile(REPO / "test/fixtures/mock_docker.py", docker)
        docker.chmod(0o755)
        refs = self.root / "refs"
        (refs / "star_index").mkdir(parents=True)
        for f in ("star_index/genomeParameters.txt", "genes.gtf", "genes.collapsed.gtf", "reference_manifest.json"):
            (refs / f).write_text("{}")
        self.fastq = self.root / "S.fastq"
        self.fastq.write_text("original input")
        self.calls = self.root / "calls.jsonl"
        self.env = {
            **os.environ,
            "PATH": str(mock_bin) + os.pathsep + os.environ["PATH"],
            "COG_BALL_SITE_CONF": str(self.root / "no-site-conf"),
            "MOCK_CALLS": str(self.calls),
        }
        self.env.pop("MOCK_FAIL_STEP", None)
        self.cmd = [
            "bash", str(REPO / "bin/cog-ball-run.sh"), "--docker", "--sample", "S", "--center", "TEST",
            "--r1", str(self.fastq), "--refs", str(refs), "--outdir", str(self.root / "out"),
        ]
        self.sample = self.root / "out/TEST/S"

    def run_sample(self, *args, fail=None, counts="ENSG1\t1\n"):
        env = {**self.env, "MOCK_COUNTS": counts}
        if fail:
            env["MOCK_FAIL_STEP"] = fail
        result = subprocess.run(self.cmd + list(args), env=env, capture_output=True, text=True)
        if fail:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def commands(self):
        return [json.loads(line)["command"] for line in self.calls.read_text().splitlines()]

    def assert_classified(self):
        for ext in CLASSIFIED_EXTS:
            self.assertTrue((self.sample / "mdall" / f"S.{ext}").is_file())
        md = json.loads((self.sample / "mdall/S.mdall.json").read_text())
        counts = (self.sample / "counts/S.htseq.dux4patched.tsv").read_bytes()
        self.assertEqual(md["input"]["counts_md5"], hashlib.md5(counts).hexdigest())
        self.assertEqual(list((self.sample / "mdall").glob(".classify.*")), [])

    def assert_unclassified(self):
        for ext in CLASSIFIED_EXTS:
            self.assertFalse((self.sample / "mdall" / f"S.{ext}").exists(), ext)
        self.assertEqual(list((self.sample / "mdall").glob(".classify.*")), [])

    def test_success_publishes_complete_classification(self):
        self.run_sample()
        self.assert_classified()

    def test_changed_inputs_and_failed_classifier_remove_old_results(self):
        self.run_sample()
        self.fastq.write_text("changed input, with different size")
        result = self.run_sample(fail="classify", counts="ENSG1\t999\n")
        self.assertEqual((self.sample / "counts/S.htseq.dux4patched.tsv").read_text(), "ENSG1\t999\n")
        self.assert_unclassified()
        self.assertIn("simulated classify failure", (self.sample / "mdall/S.mdall.log").read_text())
        self.assertIn("counting again", result.stdout)

    def test_failed_alignment_removes_old_results_and_fingerprint(self):
        self.run_sample()
        self.fastq.write_text("changed input, with different size")
        self.run_sample(fail="align")
        self.assert_unclassified()
        self.assertFalse((self.sample / "counts/.S.inputs").exists())

    def test_failed_classifier_with_reused_counts_removes_old_results(self):
        self.run_sample()
        self.run_sample(fail="classify")
        self.assert_unclassified()
        self.assertEqual(self.commands().count("cog_align.sh"), 1)

    def test_partial_classifier_failure_never_publishes_outputs(self):
        self.run_sample()
        self.run_sample(fail="classify_partial")
        self.assert_unclassified()

    def test_missing_classifier_output_prevents_publication(self):
        self.run_sample()
        result = self.run_sample(fail="classify_incomplete")
        self.assertIn("classifier output missing or empty", result.stdout)
        self.assert_unclassified()

    def test_identical_inputs_reuse_counts(self):
        self.run_sample()
        result = self.run_sample()
        self.assertIn("skipping alignment", result.stdout)
        self.assertEqual(self.commands().count("cog_count.sh"), 1)
        self.assert_classified()

    def test_keep_bam_rebuilds_missing_bam(self):
        self.run_sample()
        result = self.run_sample("--keep-bam")
        self.assertIn("retained BAM/index is missing", result.stdout)
        self.assertTrue((self.sample / "bam/S.bam").is_file())
        self.assertTrue((self.sample / "bam/S.bam.bai").is_file())
        self.assertEqual(self.commands().count("cog_align.sh"), 2)
        self.assert_classified()

    def test_keep_bam_reuses_existing_bam(self):
        self.run_sample("--keep-bam")
        self.run_sample("--keep-bam")
        self.assertEqual(self.commands().count("cog_align.sh"), 1)
        self.assert_classified()

    def test_keep_bam_rebuilds_missing_index(self):
        self.run_sample("--keep-bam")
        (self.sample / "bam/S.bam.bai").unlink()
        self.run_sample("--keep-bam")
        self.assertTrue((self.sample / "bam/S.bam.bai").is_file())
        self.assertEqual(self.commands().count("cog_align.sh"), 2)

    def test_recount_clears_bam_from_previous_inputs(self):
        self.run_sample("--keep-bam")
        self.fastq.write_text("changed input, with different size")
        self.run_sample()
        self.assertFalse((self.sample / "bam/S.bam").exists())
        self.run_sample("--keep-bam")
        self.assertEqual(self.commands().count("cog_align.sh"), 3)
        self.assertIn("changed input", (self.sample / "bam/S.bam").read_text())


@unittest.skipUnless(shutil.which("rsync"), "rsync is required")
class SyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="cog-sync-test-")
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.src = root / "local/TEST"
        self.dest = root / "hub/TEST"
        for center in (self.src, self.dest):
            (center / "S/mdall").mkdir(parents=True)
        (self.src / "S/mdall/S.mdall.json").write_text("{}")
        (self.dest / "S/mdall/S.mdall.json").write_text("{}")
        self.env = {**os.environ, "COG_BALL_SITE_CONF": str(root / "site.conf")}
        Path(self.env["COG_BALL_SITE_CONF"]).write_text(
            f"CENTER=TEST\nOUTDIR={self.src.parent}\nHUB={self.dest.parent}\n"
        )

    def sync(self, *args, site_conf=False):
        paths = [] if site_conf else [str(self.src), str(self.dest)]
        return subprocess.run(
            ["bash", str(REPO / "bin/sync_results.sh"), *paths, *args],
            env=self.env, capture_output=True, text=True,
        )

    def withdraw(self):
        shutil.rmtree(self.src / "S")

    def test_empty_source_requires_explicit_flag(self):
        self.withdraw()
        result = self.sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--allow-empty", result.stderr)
        self.assertTrue((self.dest / "S/mdall/S.mdall.json").exists())

    def test_allow_empty_removes_last_result_and_preserves_excluded_files(self):
        self.withdraw()
        protected = self.dest / "S/bam/S.bam"
        protected.parent.mkdir()
        protected.write_text("must not delete")
        result = self.sync("--allow-empty")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.dest / "S/mdall/S.mdall.json").exists())
        self.assertEqual(protected.read_text(), "must not delete")

    def test_empty_dry_run_preserves_hub(self):
        self.withdraw()
        result = self.sync("--allow-empty", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("deleting", result.stdout)
        self.assertTrue((self.dest / "S/mdall/S.mdall.json").exists())

    def test_allow_empty_still_rejects_missing_source(self):
        self.withdraw()
        self.src.rmdir()
        result = self.sync("--allow-empty")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Source not found", result.stderr)
        self.assertTrue((self.dest / "S/mdall/S.mdall.json").exists())

    def test_allow_empty_uses_site_conf(self):
        self.withdraw()
        result = self.sync("--allow-empty", site_conf=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.dest / "S/mdall/S.mdall.json").exists())

    def test_classification_staging_is_not_synced(self):
        staged = self.src / "S/mdall/.classify.fixture/S.mdall.json"
        staged.parent.mkdir()
        staged.write_text('{"incomplete":true}')
        result = self.sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.dest / "S/mdall/.classify.fixture").exists())


if __name__ == "__main__":
    unittest.main()
