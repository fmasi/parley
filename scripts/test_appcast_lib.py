import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from appcast_lib import all_enclosure_urls, newest_item, version_from_filename

APPCAST = '''<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<item><sparkle:shortVersionString>0.8.2</sparkle:shortVersionString>
<enclosure url="https://github.com/fmasi/parley/releases/download/v0.8.2/Parley-0.8.2.zip"
 sparkle:edSignature="SIG082" length="1"/></item>
<item><sparkle:shortVersionString>0.9.0</sparkle:shortVersionString>
<enclosure url="https://github.com/fmasi/parley/releases/download/v0.9.0/Parley-0.9.0.zip"
 sparkle:edSignature="SIG090" length="1"/></item>
</channel></rss>'''


class AppcastLibTests(unittest.TestCase):
    def test_newest_item_by_semver_not_order(self):
        # 0.8.2 appears first in the document; 0.9.0 must still win.
        item = newest_item(APPCAST)
        self.assertEqual(item["version"], "0.9.0")
        self.assertTrue(item["url"].endswith("/v0.9.0/Parley-0.9.0.zip"))
        self.assertEqual(item["ed_signature"], "SIG090")

    def test_all_urls(self):
        self.assertEqual(len(all_enclosure_urls(APPCAST)), 2)

    def test_version_from_filename(self):
        self.assertEqual(version_from_filename("Parley-0.9.0.zip"), "0.9.0")
        self.assertEqual(version_from_filename("Parley-0.10.3.zip"), "0.10.3")
        self.assertIsNone(version_from_filename("not-a-release.zip"))

    def test_empty_channel(self):
        self.assertIsNone(newest_item(
            '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
            '<channel></channel></rss>'))


if __name__ == "__main__":
    unittest.main()
