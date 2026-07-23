from __future__ import annotations

import unittest
from pathlib import Path

from harness.source_metrics import embedded_source_regions, text_metrics


class EmbeddedSourceRegionsTest(unittest.TestCase):
    def test_splits_rust_cfg_test_module(self) -> None:
        source = "fn main() {}\n#[cfg(test)]\nmod tests {\n}\n"

        regions = embedded_source_regions("rust", Path("pr-plan.rs"), source)

        self.assertEqual(
            regions,
            [
                ("implementation", "fn main() {}\n"),
                ("tests", "#[cfg(test)]\nmod tests {\n}\n"),
            ],
        )

    def test_splits_d_unittest_version_from_main_fallback(self) -> None:
        source = (
            "int run() { return 0; }\n"
            "version (unittest)\n{\nunittest {}\n}\n"
            "else\n{\nvoid main() {}\n}\n"
        )

        regions = embedded_source_regions("d", Path("pr_plan.d"), source)

        self.assertEqual(
            regions,
            [
                (
                    "implementation",
                    "int run() { return 0; }\nelse\n{\nvoid main() {}\n}\n",
                ),
                ("tests", "version (unittest)\n{\nunittest {}\n}\n"),
            ],
        )

    def test_split_metrics_preserve_total_lines_and_bytes(self) -> None:
        source = "fn main() {}\n#[cfg(test)]\nmod tests {\n}\n"
        regions = embedded_source_regions("rust", Path("pr-plan.rs"), source)
        assert regions is not None

        whole = text_metrics(source)
        split = [text_metrics(region) for _, region in regions]

        self.assertEqual(sum(metric["lines"] for metric in split), whole["lines"])
        self.assertEqual(sum(metric["bytes"] for metric in split), whole["bytes"])


if __name__ == "__main__":
    unittest.main()
