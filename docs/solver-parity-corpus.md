# Solver parity corpus

The app's `WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver in
[`viamin/color_matching`](https://github.com/viamin/color_matching), and the
app's earliest-wins selection mirrors `ColorMatching.IlluminantMatching`.
Neither contract was enforced before, so a change on either side could
silently alter which printable color every cell of a composition resolves to.

The server now publishes a deterministic golden-vector corpus, and this app
replays it.

## Where the corpus lives

| What | Where |
| --- | --- |
| Committed copy (this repo) | `ColorComposerCore/Tests/Fixtures/parity/v1/corpus.json` |
| Upstream original | `priv/parity/v1/corpus.json` in `viamin/color_matching` |
| Replay test | `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityTests.swift` |
| Corpus model + loader | `ColorComposerCore/Tests/ColorComposerCoreTests/ParityCorpusFixture.swift` |

The committed file is a byte-for-byte copy of the upstream fixture. The
upstream copy is regenerated with `mix parity.generate` and verified in the
server's CI with `mix parity.generate --check`, so it is stable and
deterministic.

## What the corpus contains

Each scenario carries:

- `weights` — the per-light-source channel weights (light sources the app does
  not know are listed too; both sides ignore them),
- `target` — the target response vector (a light source that is absent was
  never measured: *missing*, not zero),
- `palette` — the candidate colors with their measured response vectors,
- `expected.scores` — the server's score per candidate, or the string
  `"excluded"` when the candidate (or the target) misses a positive-weight
  measurement,
- `expected.selected_index` / `selected_hex_color` / `error` — the selection
  the server made and its weighted squared error,
- `expected.tie_broke` / `tied_indices` — explicit tie-break evidence.

The corpus is stamped with `algorithm_version`. When the server bumps it, every
expectation in the corpus moved and the app must review them in step.

## What the test asserts

`SolverParityTests` replays every scenario and checks that:

1. each candidate's score is *exactly* the server's score (bit-for-bit equal
   doubles), and candidates the server excluded are excluded here too;
2. exclusions follow the missing-measurement policy — a candidate or target
   missing any positive-weight channel is excluded, never scored as zero;
3. the solver (the real `CompositionSolver` path, not a re-implementation)
   selects the same color, with the same error, as the server;
4. ties resolve to the earliest tied candidate, matching the server's
   `earliest-index-wins` policy;
5. the corpus keeps its coverage — at least one tie scenario, one exclusion, one
   zero-weight channel and one scenario where nothing can be selected.

## Parity findings (corpus v1, `algorithm_version` 1)

- **Ties.** Four scenarios contain exact ties: a symmetric pair around the
  target, two candidates with byte-identical response vectors, a three-way tie
  on a single channel, and a mixed palette whose best trio ties. In every case
  the server selects the earliest tied candidate, and so does the app — the
  app's solver keeps the first candidate on an exact tie (`sum < best`).
- **Exclusions.** A candidate missing a positive-weight measurement is
  excluded, and so is *every* candidate when the target itself misses one.
  A missing measurement is never scored as zero brightness. The corpus also
  pins the zero-weight case: a missing measurement on a channel with weight
  `0` neither excludes the candidate nor contributes to its score.
- **Weight handling.** Channel weights scale the squared error linearly, and
  only channels with weight `> 0` are required. Unknown light sources (the
  corpus uses `ultraviolet`) are ignored by both sides.
- **Floating point.** The corpus values are exact binary fractions, so the
  app's summation order (white, red, green, blue, lps) does not change the
  result: both sides agree bit-for-bit.

## Refreshing the corpus

When the server regenerates its corpus:

```bash
# in viamin/color_matching
mix parity.generate            # rewrites priv/parity/v1/corpus.json
mix parity.generate --check    # CI gate: committed bytes match a fresh build
```

Then, in this repository:

1. copy the upstream file over the committed one:

   ```bash
   cp ../color_matching/priv/parity/v1/corpus.json \
      ColorComposerCore/Tests/Fixtures/parity/v1/corpus.json
   ```

2. update the expected digest in `ParityCorpusLoader.upstreamDigest`
   (`shasum -a 256 ColorComposerCore/Tests/Fixtures/parity/v1/corpus.json`),
3. check `algorithm_version` in the new corpus — a bump means the server's
   scoring semantics changed, so review every expectation (and the app's
   scorer) before accepting them,
4. run the suite: `cd ColorComposerCore && swift test`.

## The OpenAPI contract

The same server publishes an OpenAPI 3 document at `GET /api/v1/openapi.json`.
The app vendors that document so a typed client can be generated from it, and
`ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIContractTests.swift`
keeps the vendored copy honest: it asserts that the document declares the two
endpoints the app uses (`GET /api/v1/printer_profiles`, `GET /api/v1/colors`),
the response shapes `PaletteAPIClient` decodes, the required
`printer_profile_id` query parameter, and the bearer authentication scheme.

The document is found by name: any JSON file whose name contains `openapi`
inside `ColorComposerCore/` (or the repository checkout) is used.
