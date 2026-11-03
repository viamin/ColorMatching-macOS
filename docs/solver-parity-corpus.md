# Solver parity corpus

The permanent Swift parity test is
`ColorComposerCore/Tests/ColorComposerCoreTests/WeightedSquaredErrorParityCorpusTests.swift`.
Its fixture is adjacent at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`.

The fixture is to be copied verbatim from `viamin/color_matching#111` and must
record the immutable upstream commit SHA in `revision`. Refresh it by fetching
that committed corpus, replacing the fixture without semantic translation, and
running:

```bash
cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityCorpusTests
```

The test intentionally fails while the upstream corpus cannot be fetched: its
`revision` is `PENDING-UPSTREAM-CORPUS`. This makes the external dependency
visible rather than presenting locally reconstructed examples as the published
corpus. The follow-on implementation run must replace this placeholder and add
the requested README pointer.
