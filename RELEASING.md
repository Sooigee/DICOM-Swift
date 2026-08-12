# Releasing `DICOM-Swift`

This checkout is the development and staging home for upcoming `DICOM-Swift` changes.

## Recommended versioning strategy here

- Keep day-to-day work on `main`.
- Track user-facing changes in `CHANGELOG.md` under `## [Unreleased]`.
- If you need a candidate build from this repo before promotion, prefer a SemVer prerelease tag such as `v1.0.2-rc1` or `v1.1.0-beta1` instead of a stable tag.
- Do not publish a stable `vX.Y.Z` tag from this checkout unless maintainers have explicitly decided that it is the canonical stable release source.

## Prerelease checklist

Before cutting a prerelease candidate from this repo:

1. Confirm configured automated checks are green on `main`.
2. Review `CHANGELOG.md` and make sure `Unreleased` is accurate and user-facing.
3. Re-check README install guidance so it points to the correct package source for the intended release.
4. Run the optional-runtime preflight to see what this machine can
   actually validate before reading XCTest skips:
   - `swift run dicomtool preflight`
   - Reports active/missing/unsupported status for CharLS, OpenJPEG,
     `opj_compress`, Metal, network interop endpoints, TLS material, and
     large/conformance fixtures, with setup hints and the
     `DICOM_REQUIRE_<CAPABILITY>` environment names from
     `Tests/DicomCoreTests/Resources/ReleaseGates/OptionalRuntimeFixtureManifest.json`.
   - Exit status is nonzero only when a capability required by CI policy
     (or by `DICOM_REQUIRE_<CAPABILITY>=1` /
     `DICOM_REQUIRE_OPTIONAL_RUNTIMES=1`) is unavailable; absent optional
     capabilities print warnings and exit zero.
   - `--json` emits a machine-readable report for CI;
     `--package-root`/`--manifest` override path resolution when running
     outside the package root.
5. Run the validation gates (`Scripts/test_gates.sh`, issue #1220):
   - `Scripts/test_gates.sh quick` — deterministic unit gate for routine
     PR work (skips performance/stress/streaming/network/conformance and
     CLI process-spawning suites; ~35s vs ~8min for the full suite).
   - `Scripts/test_gates.sh fixture` — bundled + curated non-PHI fixture
     coverage; stable inputs, no network.
   - `Scripts/test_gates.sh runtime` — optional runtime/interop coverage;
     consumes the preflight JSON report and only runs suites whose
     capability is active on this machine.
   - `Scripts/test_gates.sh release` — the authoritative expensive path
     before publishing (or consuming a DICOM-Swift update in Isis):
     preflight report + release build + the full `swift test` suite. The
     gate itself exports `DICOM_REQUIRE_CHARLS=1` and
     `DICOM_REQUIRE_OPENJPEG=1` (issue #1230), plus
     `DICOM_REQUIRE_OPJ_COMPRESS=1` and `DICOM_REQUIRE_LIBJXL_TOOLS=1` for
     independent cross-codec evidence: a release candidate is rejected fast
     unless those required codec paths are active. Set the manifest's other `DICOM_REQUIRE_*` /
     `DICOM_INTEROP_SMOKE` variables to force the remaining optional legs.
     `DicomCodecCapabilities` reports the active backend, version, library
     path/source, and supported bit depths per codec runtime; CharLS and
     OpenJPEG are system dependencies loaded dynamically (never bundled),
     overridable via `DICOM_DECODER_<RUNTIME>_LIBRARY_PATH`.

   Every gate is deterministic about coverage (issue #1222): the preflight
   runs first and a missing *required* capability fails the gate before the
   test body starts; after the run, a runtime coverage summary
   (`.build/runtime-coverage/<gate>/summary.{txt,json}`) records what was
   tested, what was skipped (attributed to manifest capabilities), what was
   absent, and what was required — attach it to release review.

   Fixture, runtime, and release gates also write the issue #1435 clinical
   conformance artifacts to
   `.build/runtime-coverage/<gate>/clinical-conformance/report.{json,csv,md}`.
   These record fixture provenance/checksums, encoder and decoder versions,
   comparison and metadata rules, result, duration, optional peak RSS,
   failure location, visible corpus gaps, and backend verdicts. For the pinned
   DICOMKit cross-read/write leg, provide `DICOMKIT_CHECKOUT`, optionally set
   `DICOM_REQUIRE_DICOMKIT_INTEROP=1`, and run
   `Scripts/conformance/run_clinical_conformance.sh nightly`.

   CI policy levels:
   - **Default CI policy**: only `bundled-synthetic-fixtures` is required;
     absent optional runtimes/fixtures/services are warnings and the
     summary explicitly marks the run as *not full coverage*.
   - **Release CI policy**: promote capabilities to required with
     `DICOM_REQUIRE_<CAPABILITY>=1` (or `DICOM_REQUIRE_OPTIONAL_RUNTIMES=1`
     for all optional runtimes, plus `DICOM_INTEROP_SMOKE=1` with
     provisioned endpoints) so the release gate fails fast when the
     machine cannot actually exercise them.
6. Core package validation commands behind the gates:
   - `swift build`
   - `swift test`
   - `swift run dicomtool --help`
7. Smoke-test at least one real DICOM decode path and one CLI path that matter for the intended release notes.
8. Capture any manual follow-up needed for promotion to the stable release line.

## First stable release gates for this repo

Do **not** publish a first stable release from this checkout until all of the following are true:

- A deliberate maintainer decision has been made that this checkout should own stable releases.
- Configured automated checks are consistently green for the intended release commit.
- `CHANGELOG.md` is curated and ready to become release notes.
- Install instructions, dependency snippets, and repository links all point to the correct canonical release source.
- Library, CLI, and at least one viewer-facing integration path have been smoke-tested successfully.
- Any artifact/signing/distribution expectations are documented clearly enough that a consumer can repeat them.

## Promotion note

If stable releases continue to be cut from `ThalesMMS/DICOM-Swift`, use this checkout to prepare and validate the change set, then promote the reviewed commit into the stable release line there instead of publishing a separate stable release here.
