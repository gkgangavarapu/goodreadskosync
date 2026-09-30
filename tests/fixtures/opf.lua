-- Sample OPF documents for resolver tests.
return {
    clean = [[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>Sapiens</dc:title>
    <dc:creator opf:role="aut">Yuval Noah Harari</dc:creator>
    <dc:identifier opf:scheme="ISBN">9780062316097</dc:identifier>
    <dc:publisher>Harper</dc:publisher>
    <dc:language>en</dc:language>
    <dc:date>2015-02-10</dc:date>
    <meta name="calibre:series" content="Sapiens"/>
    <meta name="calibre:series_index" content="1"/>
  </metadata>
</package>]],

    isbn10 = [[<package><metadata>
    <dc:title>The Hobbit</dc:title>
    <dc:creator>J.R.R. Tolkien</dc:creator>
    <dc:identifier scheme="ISBN">0306406152</dc:identifier>
  </metadata></package>]],

    asin = [[<package><metadata>
    <dc:title>Some Kindle Book</dc:title>
    <dc:creator>An Author</dc:creator>
    <dc:identifier id="mobi-asin">B00J8QK4CE</dc:identifier>
  </metadata></package>]],

    goodreads = [[<package><metadata>
    <dc:title>Sapiens</dc:title>
    <dc:creator>Yuval Noah Harari</dc:creator>
    <dc:identifier>goodreads:23692271</dc:identifier>
  </metadata></package>]],

    multiple = [[<package><metadata>
    <dc:title>Multi</dc:title>
    <dc:creator>A One</dc:creator>
    <dc:creator opf:role="trl">B Two</dc:creator>
    <dc:identifier opf:scheme="ISBN">9780306406157</dc:identifier>
    <dc:identifier opf:scheme="ASIN">B00J8QK4CE</dc:identifier>
    <dc:identifier>goodreads:99</dc:identifier>
    <meta name="calibre:isbn" content="9780306406157"/>
  </metadata></package>]],

    none = [[<package><metadata>
    <dc:title>No Identifiers</dc:title>
    <dc:creator>Nobody</dc:creator>
  </metadata></package>]],

    malformed = [[<package><metadata>
    <dc:title>Broken</dc:title>
    <dc:creator>Someone
    <dc:identifier opf:scheme="ISBN">not-an-isbn
  </metadata>]],

    container = [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]],
}
