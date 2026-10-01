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
