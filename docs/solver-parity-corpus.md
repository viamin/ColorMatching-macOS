# Solver parity corpus

`ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json` is the committed
v1 golden-vector corpus for `WeightedSquaredErrorScorer`. It is produced by the
backend repository at `viamin/color_matching`, in `priv/parity/v1/corpus.json`.

Refresh it after a backend corpus change by copying that committed file verbatim,
then run:

```bash
cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityCorpusTests
```

The test replays every scenario's candidate scores and earliest-wins selection,
including ties, missing positive-weight measurements, and zero-weight channels.
Keep the corpus algorithm version and its fixture filename aligned.
