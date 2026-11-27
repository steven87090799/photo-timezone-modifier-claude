# Third-party notices

ExifTool 13.64 by Phil Harvey and contributors is redistributed under the
same terms as Perl itself (the Perl Artistic License or GPL). The checkout
includes a verified upstream source archive. The App packages the command,
complete module directory, license and README. The command uses system
`/usr/bin/perl». [ExifTool source](https://github.com/exiftool/exiftool/tree/3d7a0538324e9b04aa8930201b007009491321d2)

JPEG uses statically linked Jpegli and Highway. Its source and build-only
skcms and libjpeg-turbo headers are pinned in `NativeJpegli/dependencies.json».
The `JpegliLicenses» resources retain their BSD-3-Clause, Apache 2.0,
IJG and related upstream notices. [Jpegli source](https://github.com/google/jpegli/tree/031a0077f5799a6041004267fc12b956c1f52a20)

JPEG XL uses libjxl 0.13.0 with pinned Highway, Brotli and LittleCMS.
WebP uses the libwebp 1.6.0 native encoder and SharpYUV. The exact source
revisions and archive checksums are in `scripts/native-codecs.json».
`JXLLicenses» retains the corresponding license and patent texts. The three
JPEG XL dylibs are staged in `Contents/Frameworks/JXL» and signed inside the App.
[libjxl source](https://github.com/libjxl/libjxl/tree/5a7da83447212fe4900fc29ce97430b881caa67e)
[libwebp source](https://github.com/webmproject/libwebp/tree/4fa21912338357f89e4fd51cf2368325b59e9bd9)

The invisible NEXPRESS-derived runtime uses OxiPNG single-threaded WASM for
8-bit PNG. Its source, runtime hashes and licenses are recorded in
`CompressionWeb/THIRD_PARTY_NOTICES» and `scripts/oxipng-lock.json». AVIF and HEIF
use macOS ImageIO. RAW development uses Apple Core Image.

The App includes `DependencyManifest.json». It records source pins, build
tool versions, pre-packaging native artifacts and the packaged resource hashes.
