#!/usr/bin/env python3
"""Tests for fix_appcast_urls.py.

Run with: python3 -m unittest scripts.test_fix_appcast_urls -v
      or: cd scripts && python3 -m unittest test_fix_appcast_urls -v
"""
import os
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fix_appcast_urls import fix_appcast_urls

APPCAST_TEMPLATE = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel>
{items}
</channel>
</rss>
"""


def enclosure_url(xml_text: str, title: str) -> str:
    """Extract the enclosure url= for the <item> whose <title> matches."""
    root = ET.fromstring(xml_text)
    for item in root.findall(".//item"):
        if item.findtext("title") == title:
            return item.find("enclosure").get("url")
    raise AssertionError(f"no item titled {title!r} found")


class FixAppcastUrlsTests(unittest.TestCase):
    def _run(self, items_xml: str) -> str:
        with tempfile.NamedTemporaryFile(mode="w", suffix=".xml", delete=False, encoding="utf-8") as f:
            f.write(APPCAST_TEMPLATE.format(items=items_xml))
            path = f.name
        try:
            fix_appcast_urls(path)
            with open(path, encoding="utf-8") as f:
                return f.read()
        finally:
            os.unlink(path)

    def test_zip_url_rewritten_to_its_own_tag(self):
        # Simulates the bug: generate_appcast stamped v0.7.0's prefix onto an older v0.6.0 entry.
        result = self._run("""
            <item><title>Parley 0.6.0</title>
            <enclosure url="https://github.com/fmasi/parley/releases/download/v0.7.0/Parley-0.6.0.zip"
                       sparkle:version="300" length="1" type="application/octet-stream"/></item>
        """)
        self.assertEqual(
            enclosure_url(result, "Parley 0.6.0"),
            "https://github.com/fmasi/parley/releases/download/v0.6.0/Parley-0.6.0.zip",
        )

    def test_mixed_appcast_old_fixed_current_unchanged(self):
        # The primary production scenario: an old entry needing correction AND the current
        # entry (already correct) present in the SAME parse, confirming the two rewrites don't
        # interfere with each other.
        result = self._run("""
            <item><title>Parley 0.6.0</title>
            <enclosure url="https://github.com/fmasi/parley/releases/download/v0.7.0/Parley-0.6.0.zip"
                       sparkle:version="300" length="1" type="application/octet-stream"/></item>
            <item><title>Parley 0.7.0</title>
            <enclosure url="https://github.com/fmasi/parley/releases/download/v0.7.0/Parley-0.7.0.zip"
                       sparkle:version="416" length="1" type="application/octet-stream"/></item>
        """)
        self.assertEqual(
            enclosure_url(result, "Parley 0.6.0"),
            "https://github.com/fmasi/parley/releases/download/v0.6.0/Parley-0.6.0.zip",
        )
        self.assertEqual(
            enclosure_url(result, "Parley 0.7.0"),
            "https://github.com/fmasi/parley/releases/download/v0.7.0/Parley-0.7.0.zip",
        )

    def test_current_release_url_unaffected(self):
        result = self._run("""
            <item><title>Parley 0.7.0</title>
            <enclosure url="https://github.com/fmasi/parley/releases/download/v0.7.0/Parley-0.7.0.zip"
                       sparkle:version="416" length="1" type="application/octet-stream"/></item>
        """)
        self.assertEqual(
            enclosure_url(result, "Parley 0.7.0"),
            "https://github.com/fmasi/parley/releases/download/v0.7.0/Parley-0.7.0.zip",
        )

    def test_delta_entries_left_unchanged(self):
        url = "https://github.com/fmasi/parley/releases/download/v0.7.0/Parley-0.6.0-0.7.0.delta"
        result = self._run(f"""
            <item><title>Delta</title>
            <enclosure url="{url}" sparkle:version="416" length="1" type="application/octet-stream"/></item>
        """)
        self.assertEqual(enclosure_url(result, "Delta"), url)

    def test_non_parley_filename_pattern_left_unchanged(self):
        url = "https://github.com/fmasi/parley/releases/download/v0.7.0/SomeOtherAsset.zip"
        result = self._run(f"""
            <item><title>Other</title>
            <enclosure url="{url}" sparkle:version="416" length="1" type="application/octet-stream"/></item>
        """)
        self.assertEqual(enclosure_url(result, "Other"), url)

    def test_missing_url_attribute_does_not_crash(self):
        result = self._run("""
            <item><title>NoURL</title>
            <enclosure sparkle:version="416" length="1" type="application/octet-stream"/></item>
        """)
        # Should complete without raising, and the enclosure should still have no url attribute.
        root = ET.fromstring(result)
        item = next(i for i in root.findall(".//item") if i.findtext("title") == "NoURL")
        self.assertIsNone(item.find("enclosure").get("url"))

    def test_namespace_and_comment_preserved(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".xml", delete=False, encoding="utf-8") as f:
            f.write("""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
<channel>
<!-- a channel comment -->
<item><title>Parley 0.7.0</title><dc:creator>Frederic</dc:creator>
<enclosure url="https://github.com/fmasi/parley/releases/download/v0.7.0/Parley-0.7.0.zip"
           sparkle:version="416" length="1" type="application/octet-stream"/></item>
</channel>
</rss>
""")
            path = f.name
        try:
            fix_appcast_urls(path)
            with open(path, encoding="utf-8") as f:
                result = f.read()
        finally:
            os.unlink(path)
        self.assertIn("<!-- a channel comment -->", result)
        self.assertIn("dc:creator", result)
        self.assertIn('encoding=\'utf-8\'', result)


if __name__ == "__main__":
    unittest.main()
