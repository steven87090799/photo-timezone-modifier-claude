# Third-party notices

The source project vendors the original ExifTool 13.59 archive by Phil Harvey
and contributors, pinned and verified by scripts/prepare-exiftool.sh.
ExifTool is redistributable under the same terms as Perl itself (the Perl
Artistic License or GPL); retain the upstream LICENSE and README.

The built app includes the ExifTool command-line program, the complete lib
module directory, LICENSE and README. Development tests, HTML documentation,
and packaging examples are not installed into the app.

One explicitly documented local transport patch is applied to the command-line
program by scripts/patch-worker-eof.pl. When its native stay-open input is stdin,
EOF closes the worker instead of repeatedly waiting for bytes from a dead
parent. Growing disk argument-file behavior is unchanged. This patch changes
no metadata parser/writer or tag definition. The original archive is untouched.

Upstream: https://github.com/exiftool/exiftool/tree/2200871d9cef988051d2a99d67df3bda6cbb30a8

ExifTool runs as a separate process using macOS /usr/bin/perl. No Perl binary
or additional runtime dependency is redistributed by this project.

The native image compression tab uses an invisible runtime derived from
NEXPRESS with third-party image codecs. Their component inventory and provenance are in
`CompressionWeb/THIRD_PARTY_NOTICES`, also included in the App resources. HEIF
encoding and decoding use macOS ImageIO; no third-party HEIF converter is
bundled.

JPEG encoding uses Google's Jpegli, statically linked with Highway. These
sources and the libjpeg-compatible public headers are pinned by revision and
archive SHA-256 in `NativeJpegli/dependencies.json`. The build also fetches the
pinned skcms source required by upstream's CMake configuration; its CMS library
is not linked into the App. JPEG uses conventional 8-bit YCbCr, not XYB.

The App's `JpegliLicenses` resource directory contains the upstream Jpegli,
Highway, skcms and libjpeg-turbo notices and source manifest. Jpegli is BSD-3-Clause;
Highway's license offers Apache-2.0 or BSD-3-Clause. libjpeg-turbo's header notices
and IJG license are retained. No Homebrew runtime libraries are shipped.

Upstream: https://github.com/google/jpegli/tree/031a0077f5799a6041004267fc12b956c1f52a20
