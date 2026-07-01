#!/usr/bin/env python3
"""Restore each appcast entry's download URL to its own release tag.

generate_appcast's --download-url-prefix applies to EVERY entry it (re)writes, including older
releases already accumulated in the archives folder for delta generation -- so on the 2nd+
release, it stamps the current release's tag onto every older entry's URL too, breaking their
downloads. This walks the appcast, parses each .zip entry's version from its filename, and
rewrites its URL to reference that version's own GitHub release tag instead.

.delta entries intentionally keep whatever prefix generate_appcast gave them: all accumulated
deltas are re-uploaded to every GitHub release (see docs/release-checklist.md step 5), so the
current release's tag is the correct download location for all of them, not just the newest .zip.

Usage:
    python3 scripts/fix_appcast_urls.py <path-to-appcast.xml>
"""
import re
import sys
import xml.etree.ElementTree as ET


def fix_appcast_urls(path: str) -> None:
    # Re-register every namespace prefix the file actually declares (not just "sparkle") before
    # parsing, so ElementTree round-trips them by their real prefix on write instead of inventing
    # ns0:/ns1:-style aliases for anything it wasn't told about -- e.g. if generate_appcast ever
    # adds dc:/atom: elements, an unregistered namespace would otherwise make the appcast unparseable.
    with open(path, encoding="utf-8") as f:
        raw = f.read()
    for prefix, uri in re.findall(r'xmlns:(\w+)=["\']([^"\']+)["\']', raw):
        ET.register_namespace(prefix, uri)

    # insert_comments=True (Python >= 3.8) so any XML comments in the file survive the round-trip
    # instead of being silently dropped -- ET.parse()'s default behavior discards them.
    parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
    tree = ET.parse(path, parser)

    for enclosure in tree.findall(".//enclosure"):
        url = enclosure.get("url", "")
        match = re.search(r"/Parley-(\d+\.\d+\.\d+)\.zip$", url)
        if match:
            fixed = re.sub(r"/releases/download/[^/]+/", f"/releases/download/v{match.group(1)}/", url)
            enclosure.set("url", fixed)

    # encoding="utf-8" (not "unicode") so the written bytes match the declared encoding --
    # "unicode" writes a text string but still stamps an encoding='us-ascii' declaration
    # regardless of content, which would be wrong the moment a title/note ever contains a
    # non-ASCII character.
    tree.write(path, xml_declaration=True, encoding="utf-8")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: python3 {sys.argv[0]} <path-to-appcast.xml>", file=sys.stderr)
        sys.exit(1)
    fix_appcast_urls(sys.argv[1])
