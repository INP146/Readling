#!/usr/bin/env python3
"""Writes the small test books used by the data fixtures (see docs/data-versioning.md):

  formulas.epub  MathML and MathJax-style TeX formulas, tables, a rule, styled lists, two chapters
  verse.txt      a short Gutenberg-style text with chapter headings

The output is deterministic, so running it again gives the same bytes.
Usage: python3 -I ReadlingTests/Fixtures/make_fixture_books.py
"""

import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
TIME = (1980, 1, 1, 0, 0, 0)

CONTAINER = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
"""

OPF = """<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="id">readling-fixture-formulas</dc:identifier>
    <dc:title>Formulas and Tables</dc:title>
    <dc:creator>Readling Tests</dc:creator>
    <dc:language>en</dc:language>
    <meta property="dcterms:modified">2026-11-28T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="c1" href="models.xhtml" media-type="application/xhtml+xml" properties="mathml"/>
    <item id="c2" href="prices.xhtml" media-type="application/xhtml+xml"/>
    <item id="css" href="style.css" media-type="text/css"/>
  </manifest>
  <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>
"""

NAV = """<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Contents</title></head>
<body><nav epub:type="toc"><ol>
  <li><a href="models.xhtml">Models</a></li>
  <li><a href="prices.xhtml">Prices</a></li>
</ol></nav></body></html>
"""

MODELS = """<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Models</title><link rel="stylesheet" href="style.css"/></head>
<body>
<h1>Models</h1>
<p>A statistician writes a model as <span class="math inline">\\(Y=f(X)+\\epsilon\\)</span>, where the error is small.</p>
<p>The square of a number grows quickly: <math xmlns="http://www.w3.org/1998/Math/MathML"><msup><mi>x</mi><mn>2</mn></msup></math> doubles its curvature, and half of one is <math xmlns="http://www.w3.org/1998/Math/MathML"><mfrac><mn>1</mn><mn>2</mn></mfrac></math>.</p>
<math xmlns="http://www.w3.org/1998/Math/MathML" display="block"><munderover><mo>&#x2211;</mo><mrow><mi>i</mi><mo>=</mo><mn>1</mn></mrow><mi>n</mi></munderover><mi>i</mi><mo>=</mo><mfrac><mrow><mi>n</mi><mo>(</mo><mi>n</mi><mo>+</mo><mn>1</mn><mo>)</mo></mrow><mn>2</mn></mfrac></math>
<p>She looked at the curious formula and smiled, because the meaning was suddenly plain.</p>
<p>\\[\\hat{Y} = \\sum_{i} \\beta_i x_i\\]</p>
<hr/>
<ol type="a"><li>first, estimate the coefficients</li><li>then, check the residuals</li></ol>
<p>Prices are written as $5 and $6 and must stay as they are.</p>
</body></html>
"""

PRICES = """<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Prices</title></head>
<body>
<h1>Prices</h1>
<p>The shopkeeper kept a careful ledger of everything she sold.</p>
<table>
  <caption>Ledger</caption>
  <tr><th>Item</th><th>Cost</th></tr>
  <tr><td>Tea</td><td>3.50</td></tr>
  <tr><td>Coffee with milk</td><td>12.00</td></tr>
  <tr><td colspan="2">Total <b>15.50</b></td></tr>
</table>
<p>At the end of the day the ledger balanced, and the shopkeeper was content.</p>
<table>
  <tr><td>I.</td><td>Down the Rabbit-Hole, in which Alice follows a rabbit and falls a very long way</td></tr>
  <tr><td>II.</td><td>The Pool of Tears</td></tr>
</table>
<p>Nothing else happened, which was exactly how the shopkeeper liked her evenings.</p>
</body></html>
"""

CSS = "body { font-family: serif; }\ntable { border-collapse: collapse; }\n"

TXT = """The Project Gutenberg eBook of Small Verses

CHAPTER I.

The wind was cold upon the hill,
And all the little birds were still.

A traveller came along the road and paused beside the gate, wondering whether anyone was home.

CHAPTER II.

The door was opened by a cheerful woman who invited him in for tea.

They talked for a long while about the weather, the harvest, and the curious habits of the neighbour's goat.
"""


def entry(archive: zipfile.ZipFile, name: str, data: str, compress: bool = True) -> None:
    info = zipfile.ZipInfo(name, TIME)
    info.compress_type = zipfile.ZIP_DEFLATED if compress else zipfile.ZIP_STORED
    info.external_attr = 0o644 << 16
    archive.writestr(info, data.encode("utf-8"))


def main() -> None:
    with zipfile.ZipFile(HERE / "formulas.epub", "w") as archive:
        entry(archive, "mimetype", "application/epub+zip", compress=False)
        entry(archive, "META-INF/container.xml", CONTAINER)
        entry(archive, "OEBPS/content.opf", OPF)
        entry(archive, "OEBPS/nav.xhtml", NAV)
        entry(archive, "OEBPS/models.xhtml", MODELS)
        entry(archive, "OEBPS/prices.xhtml", PRICES)
        entry(archive, "OEBPS/style.css", CSS)
    (HERE / "verse.txt").write_text(TXT, encoding="utf-8")


if __name__ == "__main__":
    main()
