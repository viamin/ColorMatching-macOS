# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`
is exercised by `WeightedSquaredErrorParityCorpusTests` on every `swift test` run.
It checks the selected palette entry and the resulting score for weighted channels,
ties, excluded candidates, zero-weight channels, and fully unmatched targets.

The canonical corpus is published by the `color_matching` project in
[PR #111](https://github.com/viamin/color_matching/pull/111). This test-writing
run could not download that private upstream artifact (GitHub returned 404), so
the committed fixture is a schema-versioned bootstrap corpus rather than a claim
that it is the upstream export.

When the upstream corpus is available, replace this fixture verbatim, retain its
source revision in the fixture metadata, and run `cd ColorComposerCore && swift test`.
The implementation run must also add the requested README link and refresh steps.
