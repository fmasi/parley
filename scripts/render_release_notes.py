"""Render release-notes Markdown into the HTML fragment Sparkle shows in its update dialog.

Single source of truth: author `release/release-notes/<version>.md` once; this renders it to
`release/updates/Parley-<version>.html` so the in-app notes and the GitHub release body never drift.

Stdlib only (no pip) — release tooling stays dependency-light. Supports the subset release notes
actually use: ATX headings, paragraphs, unordered/ordered lists, fenced code, and inline
bold/italic/code/links. Output is a fragment (no <html>/<body>) — Sparkle injects it into its pane.
"""
import html
import re
import sys

_CODE = re.compile(r"`([^`]+)`")
_LINK = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")
_BOLD = re.compile(r"\*\*([^*]+)\*\*")
_ITAL = re.compile(r"\*([^*]+)\*")
_HEADING = re.compile(r"(#{1,6})\s+(.*)")
_ULI = re.compile(r"[-*]\s+")
_OLI = re.compile(r"\d+\.\s+")


def _inline(text):
    """Inline formatting on one logical line. HTML-escape first, then protect code spans from the
    emphasis/link passes, then restore them last so `*` or `[` inside code is never reinterpreted."""
    text = html.escape(text, quote=True)
    codes = []

    def _stash(m):
        codes.append(m.group(1))
        return "\x00%d\x00" % (len(codes) - 1)

    text = _CODE.sub(_stash, text)
    text = _LINK.sub(r'<a href="\2">\1</a>', text)
    text = _BOLD.sub(r"<strong>\1</strong>", text)
    text = _ITAL.sub(r"<em>\1</em>", text)
    text = re.sub(r"\x00(\d+)\x00", lambda m: "<code>%s</code>" % codes[int(m.group(1))], text)
    return text


def render_markdown(md):
    # Normalize CRLF/CR (GitHub web editor / Windows checkout) so headings don't keep a trailing \r.
    lines = md.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    blocks = []
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        if line.strip() == "":
            i += 1
            continue
        if line.startswith("```"):
            i += 1
            code = []
            while i < n and not lines[i].startswith("```"):
                code.append(lines[i])
                i += 1
            i += 1  # skip the closing fence
            body = "".join(html.escape(c, quote=True) + "\n" for c in code)
            blocks.append("<pre><code>%s</code></pre>" % body)
            continue
        m = _HEADING.match(line)
        if m:
            level = len(m.group(1))
            blocks.append("<h%d>%s</h%d>" % (level, _inline(m.group(2)), level))
            i += 1
            continue
        if _ULI.match(line):
            items = []
            while i < n and _ULI.match(lines[i]):
                items.append("<li>%s</li>" % _inline(_ULI.sub("", lines[i], count=1)))
                i += 1
            blocks.append("<ul>\n%s\n</ul>" % "\n".join(items))
            continue
        if _OLI.match(line):
            items = []
            while i < n and _OLI.match(lines[i]):
                items.append("<li>%s</li>" % _inline(_OLI.sub("", lines[i], count=1)))
                i += 1
            blocks.append("<ol>\n%s\n</ol>" % "\n".join(items))
            continue
        para = []
        while (i < n and lines[i].strip() != "" and not lines[i].startswith("```")
               and not _HEADING.match(lines[i]) and not _ULI.match(lines[i])
               and not _OLI.match(lines[i])):
            para.append(lines[i])
            i += 1
        blocks.append("<p>%s</p>" % _inline(" ".join(para)))
    return "\n".join(blocks)


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: render-release-notes.py <input.md> <output.html>\n")
        return 2
    src, dst = argv[1], argv[2]
    try:
        with open(src, encoding="utf-8") as f:
            md = f.read()
    except OSError as e:
        sys.stderr.write("error: cannot read %s: %s\n" % (src, e))
        return 2
    if md.strip() == "":
        sys.stderr.write("error: %s is empty — refusing to render blank release notes\n" % src)
        return 2
    try:
        with open(dst, "w", encoding="utf-8") as f:
            f.write(render_markdown(md) + "\n")
    except OSError as e:
        sys.stderr.write("error: cannot write %s: %s\n" % (dst, e))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
