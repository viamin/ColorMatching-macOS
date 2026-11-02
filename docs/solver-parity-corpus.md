# Solver parity corpus (issue #39)

`ColorComposerCore`'s `WeightedSquaredErrorScorer` deliberately mirrors the
Elixir `ColorMatching.WeightedSquaredError` solver in the
[`color_matching`](https://github.com/viamin/color_matching) backend, so the
client and server agree on which palette color wins for a given target. This
document describes how that parity is checked and kept up to date.

> **Status:** the upstream corpus (viamin/color_matching#111) had not been
> published as of this PR, so the vendored corpus file described below does
> not exist yet in this repository. `SolverParityCorpusTests` fails loudly
> with instructions until it is vendored; see that test file for the exact
> steps. This note belongs in the top-level README once the corpus lands —
> see the PR for issue #39 for that follow-up.

## Where the corpus lives

Once published, the corpus is vendored at:

```
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver_parity_corpus.json
```

A hand-derived sample fixture already lives alongside it
(`solver_parity_corpus.sample.json`) purely to exercise the loader and
solving path (tie-break, exclusion, normal selection) before the real corpus
exists. It is not a substitute for the vendored corpus and is not graded
against the Elixir implementation.

## Corpus schema

```json
{
  "cases": [
    {
      "name": "human-readable case name",
      "weights": { "white": 0.5, "red": 1.0, "green": 1.0, "blue": 0.0, "lps": 1.5 },
      "target": { "white": 0.8, "red": 0.2, "green": 0.7, "blue": 0.1, "lps": 0.5 },
      "candidates": [
        { "id": 1, "responses": { "white": 0.5, "red": 0.1, "green": 0.4, "blue": 0.0, "lps": 0.3 } }
      ],
      "expected_selected_id": 1,
      "expected_score": 0.205,
      "tags": []
    }
  ]
}
```

- `weights` / `target` / a candidate's `responses` are keyed by the same
  lighting-condition strings as the `color_matching` API (`white`, `red`,
  `green`, `blue`, `lps`); a channel absent from a candidate's `responses` is
  an unmeasured channel, matching the exclusion semantics in
  `WeightedSquaredErrorScorer`.
- `expected_selected_id` is `null` when every candidate is excluded for that
  case (no source image / weight combination can be matched).
- `expected_score` is optional; when present it is asserted with `1e-9`
  tolerance.
- `tags` is informational (e.g. `"tie"`, `"exclusion"`) and not asserted on.

`SolverParityCorpusTests` runs every case through the real
`CompositionSolver` + `WeightedSquaredErrorScorer` pipeline (a 1×1 grid per
active channel) rather than a parallel hand-rolled reimplementation, so it
exercises the same selection and earliest-candidate tie-break code path the
app uses.

## Refreshing the corpus

1. Pull the latest corpus from viamin/color_matching#111.
2. Overwrite `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver_parity_corpus.json`
   with it, translated into the schema above if the upstream format differs.
3. Run `cd ColorComposerCore && swift test --filter SolverParityCorpusTests`.
4. Record any ties, exclusions, or weight-handling differences the corpus
   surfaced in the PR description for the change that refreshed it.
