# PhotoTimezone 3.5.0 implementation and validation boundaries

Date: 2026-10-01. Source input: user-provided archive at e1607479.
The upstream follow-up at 2a899411 (visible Sony option and lens fallbacks)
was inspected and those behaviors were retained in this implementation.

## Chosen safety contract

Production performs NO photo/image/preview/MakerNotes content hash. Numeric
metadata snapshots (-n, duplicate group identifiers, unknown tags, structured
values), unchanged date/subsecond maps, explicit offset-only assignments, and
nanosecond stat identities replace the repeated whole-file reads. This is a
tradeoff explicitly selected by the user, NOT proof of identical image bytes.
Unknown binary contents and adversarial concurrent writers are not certified.

All write entry points use all three ExifIFD OffsetTime fields; there is no single-field write mode. Fill-missing preserves
existing offsets; replace-all only replaces offsets. No missing date is created,
no wall-clock arithmetic is performed, and XMP dates are never silently synced.
The chosen fixed offset must be appropriate for each associated timestamp.

## Implementation by audit finding

| Finding | Disposition in 3.5.0 |
|---|---|
| F01 image integrity | Hash-based image verification intentionally removed per user; no replacement claim of binary integrity. |
| F02 display rounding | Numeric JSON snapshots, exact date/subsecond maps and a fine GPS-change regression. |
| F03 Sony private bytes | Only enumerated layout pointers may differ; metadata-only limits shown; no MakerNotes byte guarantee. |
| F04 publication ambiguity | Durable intent before mutation, explicit published/unconfirmed state, startup review and retry blocking. |
| F05 application conflicts | Embedded/sidecar XMP diagnostics and preserved values; ON1/LR/cloud end-to-end validation remains external. |
| F06 defaults | GUI/API are fixed to all three standard EXIF offset fields; Sony compatibility on, copied sidecars on, fill-missing and copy output by default in GUI. |
| F07 malformed values | Strict capture calendar/offset checks; absent ancillary dates are reported, never invented. |
| F08 stale preview | Device/inode/size/mtime/ctime identities checked across preview, staging and commit; final path race not claimed eliminated. |
| F09 sidecars | Detect .xmp/.on1/.acr, copy unchanged, preserve shared companions, reject collisions and changed sources. |
| F10 catalogue costs | Background actor, cached natural ordering and independently throttled projections. |
| F11 event queue | Bounded/lossless queue with producer backpressure and termination wake-up; cancelled consumer tested. |
| F12 memory bounds | 16 MiB stdout / 256 KiB stderr; 8 MiB xattrs and XMP diagnostic budget; session recycling. |
| F13 destination cost | Once-per-job root index and ancestor lookup instead of rebuilding all roots per photo. |
| F14 filesystem attrs | Nanosecond mtime and typed birthtime/mode comparison, bounded xattrs; ctime naturally changes on replacement. |
| F15 restore | Correct max(current,backup) capacity; explicit whole-file restore, retained current version. Field-only undo is NOT implemented. |
| F16 tests | Portable core and real ExifTool fixture tests; new fault/state/bounds regressions; stress requires first-pass success. |
| F17 repeated I/O | Removed all production file/image hashes; one recycled ExifTool worker per job; clone/copy candidate and necessary sync retained. |
| F18 log export | Detached staged file copy rather than full Data read on MainActor. |
| F19 thumbnails | CGImage result without PNG round trip, identity-keyed cache, stale/cancelled result guard, no forced full ARW sidebar decode. |
| F20 telemetry | App-only telemetry remains explicitly labeled; child RSS/CPU aggregation is not implemented. |
| F21 footprint | Runtime allowlist, full lib and license retained, no duplicate PNG in app; -Osize and stripped symbols. |
| F22 cancellation | Read/worker cancellation, safe commit boundary retained; no interruption between publication and bookkeeping. |
| F23 retained files | Active/history manifests and explicit review; backups/orphan candidates are not automatically deleted. Retention UI not implemented. |
| F24 misleading preview | External-open action explicitly named, disabled during work; not described as guaranteed read-only. |
| F25 aliases | Device/inode deduplication, original hardlink replacement refused, copy mode remains available. |
| F26 Int.min | Overflow-safe formatting and rejection before mutation; regression test. |
| F27 releases | Native macOS CI is Apple Silicon-only; shipping baseline is macOS 27+. Linux core validation does not certify macOS UI, signing or real RAW compatibility. |
| F28 architecture | ViewModel separated, dedicated transport/verifier/identity/transaction/destination/catalogue modules; ARW UTI declaration aligned. |

## ExifTool lifecycle patch

The original 13.59 archive is pinned and unmodified. Preparation applies one
reviewable EOF-only CLI patch using scripts/patch-worker-eof.pl: stdin EOF ends
stay-open mode. The stock implementation waits even after its owner dies. No
metadata parser or writer is patched. Explicit file-based stay-open behavior
is retained. A real helper-parent SIGKILL and a closed command pipe both caused
the patched worker to exit during this session. This is NOT a power-cut test of
photo storage durability. Child locale is the guaranteed POSIX C locale;
filename UTF-8 is requested explicitly. Worker recycling cannot inject missing
host-locale warnings into an otherwise unchanged metadata snapshot.

## Resource measurement

Pinned upstream tree after the EOF patch: 34,985,439 bytes. Installed runtime
subset: 20,812,510 bytes. Runtime-resource reduction: 14,172,929 bytes (40.51%).
An additional 1,292,382-byte PNG is omitted from the built app in favor of ICNS.
Combined saved resources: 15,465,311 bytes. These are resource bytes, NOT the
full app size or a measured reduction in RAM. The compact runtime passed a
JPEG three-offset read/write smoke check with its original dates unchanged.

## Validation that must not be overstated

Development host: Linux x86_64 / Swift 6.2.1 / system Perl / ExifTool 13.59 plus
the documented transport patch. SwiftUI can be syntax-parsed here but cannot
be fully typechecked or executed without an Apple SDK. Native CI results must
be checked separately. Synthetic tiny JPEG/TIFF stress is NOT a real-camera
RAW benchmark. Older macOS 3.4.x measurements in VALIDATION.md are historical,
not new 3.5.0 measurements, and cannot be compared as if measured on one host.

ON1 Photo RAW, Lightroom, Immich and Google Photos were not run on this host.
Metadata conflicts are surfaced, not guessed away. Hardware faults, hostile
concurrent filesystem mutation, unsupported RAW variants, catalog caches and
cloud asset refresh behavior remain outside these automated fixture results.
Use independent copies for the first real-camera/application acceptance run.

Application writes use no content hashes. Test-only byte comparisons and
supply-chain/source-transfer checksums remain intentionally separate.

## Completed Linux run

All 78 tests in 6 suites passed with stress enabled (119.639 seconds). The
1,000-photo mixed JPEG/TIFF write had zero unexpected first-pass failures,
verified 1,000 original backups and restored 10. The deliberate corrupt input
was rejected. Scan: 3.335 s; writing: 39.429 s. A separate 1,000-copy run took
39.243 s with all 1,000 sources byte-checked unchanged and no retries. These
fixtures are tiny; the numbers do not predict RAW throughput on a Mac.
See docs/validation-3.5.json and docs/tests-linux-3.5.log.

## PR #2 review follow-up (native macOS, 2026-10-01)

Review reproduced these defects and corrected them:

- **P1, macOS copy hangs:** Darwin directory URLs can produce `/..` after deleting
  the last path component of `/`. DestinationPlan only compared parent equality,
  causing an unbounded loop and a saturated CPU in both timezone and GPS copy
  output. A sampled live test runner located the loop in DestinationPlan.output.
  Stop explicitly at filesystem root. Direct file/directory mapping and the
  existing end-to-end copy/GPS tests now pass. The earlier assumption that this
  was a SwiftPM runner problem was incorrect. CI now runs the full native suite.
- **P1, incomplete GPS detection:** partial EXIF/XMP GPS tags (for example speed
  or image direction) and structured IPTC XMP location fields also count as
  existing GPS. Detect the complete EXIF GPS group and flattened/structured XMP
  GPS fields. Regressions prove insertion is skipped without changing photo or
  sidecar bytes or creating an original backup.
- **P1, unreliable XMP diagnosis:** a JPEG renamed `.xmp` previously returned
  successful empty selected-tag JSON and could permit GPS insertion. Require
  actual XMP file type and warning/error-free parsing to establish GPS absence.
- **P2, rescan:** inspection establishes a new file identity after external edits;
  mutations still reject a changed identity from the approved preview.
- **P2, journal compatibility:** persist the unknown-GPS flag and complete EXIF
  GPS-presence flag; old reports without these fields remain decodable.
- **P2, sidecar races:** re-enumerate the recognized sidecar set immediately before
  publication, rejecting additions/removals as well as the existing source identity
  checks. This narrows the race; it does not certify hostile concurrent writers.
- **Build compatibility:** RecoveryView uses the project's existing StateObject /
  ObservableObject pattern. Bare State attributes failed with the macOS 27 CLT
  toolchain because it lacks SwiftUIMacros; the replacement compiles natively.

Local macOS 27 / Swift 6.4 full regression result: 88 discovered tests in six
suites, 86 passed and two opt-in thousand-photo stress tests skipped, 21.409 s.
This includes five new review regressions and real pinned ExifTool fixture I/O.
All photos used here were generated fixtures or bundled vendor test samples;
user photos were not modified. Build/test artifacts were staged outside the
FileProvider-managed Documents directory to avoid its injected FinderInfo xattr
breaking ad-hoc signature validation. This is a local build-environment limitation.

The three-offset contract, no clock/date changes, metadata-only production
verification, copy defaults and backup/publication safeguards are preserved.
Real camera RAW/application acceptance and power-loss behavior
execution remain unverified by these fixture tests. Prior Linux stress results
above are historical and were not rerun for this follow-up.
