from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("pi_ssh_clipboard", Path(__file__).with_name("server.py"))
assert SPEC is not None and SPEC.loader is not None
server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server)


class ClipboardServerTests(unittest.TestCase):
    def test_types_are_filtered_deduplicated_and_preferred(self) -> None:
        payload = b"text/plain\nimage/webp\nimage/png;charset=binary\nimage/png\n"
        with patch.object(server, "_run_wl_paste", return_value=payload):
            self.assertEqual(server.available_image_types(), ["image/png", "image/webp"])

    def test_signatures_reject_mislabeled_clipboard_data(self) -> None:
        self.assertTrue(server.has_valid_signature("image/png", b"\x89PNG\r\n\x1a\nrest"))
        self.assertTrue(server.has_valid_signature("image/jpeg", b"\xff\xd8\xffrest"))
        self.assertTrue(server.has_valid_signature("image/webp", b"RIFFxxxxWEBPrest"))
        self.assertTrue(server.has_valid_signature("image/gif", b"GIF89arest"))
        self.assertFalse(server.has_valid_signature("image/png", b"not an image"))

    def test_read_image_requires_advertised_type_and_size_limit(self) -> None:
        png = b"\x89PNG\r\n\x1a\nrest"
        with patch.object(server, "available_image_types", return_value=["image/png"]):
            with patch.object(server, "_run_wl_paste", return_value=png):
                self.assertEqual(server.read_image("image/png"), png)
                self.assertIsNone(server.read_image("image/jpeg"))
            with patch.object(server, "_run_wl_paste", return_value=b"x" * (server.MAX_IMAGE_BYTES + 1)):
                self.assertIsNone(server.read_image("image/png"))


if __name__ == "__main__":
    unittest.main()
