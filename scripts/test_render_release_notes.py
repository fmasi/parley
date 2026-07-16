import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from render_release_notes import render_markdown

CLI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "render-release-notes.py")


class RenderMarkdownTests(unittest.TestCase):
    def test_heading_levels(self):
        self.assertEqual(render_markdown("# Title"), "<h1>Title</h1>")
        self.assertEqual(render_markdown("### Sub"), "<h3>Sub</h3>")

    def test_paragraph_and_inline(self):
        self.assertEqual(
            render_markdown("Fixed **crash** in `run()` see [#135](https://x/135)."),
            '<p>Fixed <strong>crash</strong> in <code>run()</code> '
            'see <a href="https://x/135">#135</a>.</p>')

    def test_italic(self):
        self.assertEqual(render_markdown("*measured*, not guessed"),
                         "<p><em>measured</em>, not guessed</p>")

    def test_unordered_list(self):
        self.assertEqual(render_markdown("- one\n- two"),
                         "<ul>\n<li>one</li>\n<li>two</li>\n</ul>")

    def test_ordered_list(self):
        self.assertEqual(render_markdown("1. first\n2. second"),
                         "<ol>\n<li>first</li>\n<li>second</li>\n</ol>")

    def test_fenced_code_is_escaped_verbatim(self):
        self.assertEqual(render_markdown("```\na < b && c\n```"),
                         "<pre><code>a &lt; b &amp;&amp; c\n</code></pre>")

    def test_html_escaping_in_text(self):
        self.assertEqual(render_markdown('a < b & "c"'),
                         '<p>a &lt; b &amp; &quot;c&quot;</p>')

    def test_blank_lines_separate_paragraphs(self):
        self.assertEqual(render_markdown("one\n\ntwo"),
                         "<p>one</p>\n<p>two</p>")

    def test_crlf_line_endings_stripped(self):
        self.assertEqual(render_markdown("# Title\r\n\r\nbody\r"),
                         "<h1>Title</h1>\n<p>body</p>")

    def test_code_span_protects_asterisks(self):
        self.assertEqual(render_markdown("`a*b*c`"),
                         "<p><code>a*b*c</code></p>")

    def test_cli_rejects_empty_file(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "e.md")
            open(src, "w").close()
            out = os.path.join(d, "e.html")
            r = subprocess.run([sys.executable, CLI, src, out],
                               capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("empty", r.stderr.lower())

    def test_cli_writes_output(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "n.md")
            with open(src, "w") as f:
                f.write("# Parley 0.9.0\n\nFixed **crash**.")
            out = os.path.join(d, "n.html")
            r = subprocess.run([sys.executable, CLI, src, out],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            with open(out) as f:
                body = f.read()
            self.assertIn("<h1>Parley 0.9.0</h1>", body)
            self.assertIn("<strong>crash</strong>", body)


if __name__ == "__main__":
    unittest.main()
