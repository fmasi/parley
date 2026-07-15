"""Pure appcast parsing for verify-release-feed.sh — no network, no side effects, unit-testable.

The Sparkle appcast is RSS with a sparkle: namespace. "Newest" is by semantic version, not document
order, because generate_appcast's entry order is not guaranteed.
"""
import re
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def _semver(v):
    return tuple(int(x) for x in v.split("."))


def newest_item(appcast_xml):
    """Return {version, url, ed_signature} for the highest-semver item, or None if there are none."""
    root = ET.fromstring(appcast_xml)
    best = None
    for item in root.findall(".//item"):
        version = item.findtext("{%s}shortVersionString" % SPARKLE)
        enclosure = item.find("enclosure")
        if version is None or enclosure is None:
            continue
        candidate = {
            "version": version,
            "url": enclosure.get("url"),
            "ed_signature": enclosure.get("{%s}edSignature" % SPARKLE),
        }
        if best is None or _semver(version) > _semver(best["version"]):
            best = candidate
    return best


def all_enclosure_urls(appcast_xml):
    root = ET.fromstring(appcast_xml)
    return [e.get("url") for e in root.findall(".//enclosure") if e.get("url")]


def version_from_filename(name):
    m = re.search(r"Parley-(\d+\.\d+\.\d+)\.zip$", name)
    return m.group(1) if m else None
