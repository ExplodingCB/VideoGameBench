import tempfile
import unittest
from pathlib import Path

from bench import balatro_supervisor


class SyncModFilesTests(unittest.TestCase):
    def test_sync_mod_files_copies_existing_mod_files(self) -> None:
        with tempfile.TemporaryDirectory() as source_dir, tempfile.TemporaryDirectory() as target_dir:
            source = Path(source_dir)
            target = Path(target_dir)
            (source / "state.lua").write_text("state from repo\n", encoding="utf-8")
            (source / "format.lua").write_text("format from repo\n", encoding="utf-8")
            (source / "server.lua").write_text("server from repo\n", encoding="utf-8")

            copied = balatro_supervisor.sync_mod_files(
                source_dir=str(source),
                target_dir=str(target),
            )

            self.assertEqual(
                {Path(path).name for path in copied},
                {"state.lua", "format.lua", "server.lua"},
            )
            self.assertEqual((target / "state.lua").read_text(encoding="utf-8"), "state from repo\n")
            self.assertEqual((target / "format.lua").read_text(encoding="utf-8"), "format from repo\n")
            self.assertFalse((target / "actions.lua").exists())

    def test_sync_mod_files_creates_target_directory(self) -> None:
        with tempfile.TemporaryDirectory() as source_dir, tempfile.TemporaryDirectory() as temp_root:
            source = Path(source_dir)
            target = Path(temp_root) / "nested" / "BalatroBench"
            (source / "state.lua").write_text("fresh state\n", encoding="utf-8")

            copied = balatro_supervisor.sync_mod_files(
                source_dir=str(source),
                target_dir=str(target),
            )

            self.assertEqual(copied, [str(target / "state.lua")])
            self.assertTrue(target.is_dir())
            self.assertEqual((target / "state.lua").read_text(encoding="utf-8"), "fresh state\n")


if __name__ == "__main__":
    unittest.main()
