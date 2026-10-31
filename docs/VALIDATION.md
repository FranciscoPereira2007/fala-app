# Validation of the full source publication

Checked on 2026-10-31:

- Full `FalaMac` unsigned Debug build: passed.
- Full `Fala` iOS Simulator build (including keyboard and widgets): passed.
- Windows Python source syntax: passed.
- Windows session-image/media regression test: passed on macOS with synthetic fixtures.
- Relay integration tests against a local worker: 6 checks passed.
- Account-service tests against a local worker with test-only authentication:
  11 checks passed, including forged credentials, isolation, logout and deletion.
- Clean source publication reviewed for packaging, signing references and runtime
  file exclusions. The private Git history is not being published.

This report concerns the full application. Tests of the earlier standalone
`fala-dictation` extraction are not being presented as validation of the complete
Fala app. No new Windows GUI run, full-app physical-iPhone regression suite,
Android build, App Store upload or production relay deployment was performed
as part of this source publication. Existing downloadable binaries retain their
own release versions; they were not replaced by this publication.
