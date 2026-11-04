# Weighted squared-error parity corpus

The committed fixture at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity_corpus.json`
is replayed by `WeightedSquaredErrorParityCorpusTests`. It checks the selected
candidate ID, including first-candidate ties, excluded candidates with a missing
active response, and zero-weight channels.

The source of truth is `viamin/color_matching#111`. When that dependency
publishes a revised corpus, copy its committed JSON into the fixture path,
preserve its upstream revision in this document or the fixture metadata, and
run `cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityCorpusTests`.

Do not regenerate expected selections in Swift: the corpus must remain an
external solver oracle so a shared implementation mistake cannot mask drift.
