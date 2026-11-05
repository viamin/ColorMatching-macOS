# Issue #39 verification plan

| Criterion | Smallest credible verification | Red-phase status |
| --- | --- | --- |
| Generated OpenAPI client preserves the palette contract | Unit tests issue `GET /api/v1/printer_profiles` and `GET /api/v1/colors?printer_profile_id=N`, asserting JSON accept headers, query encoding, and decoded envelopes. | Added in `PaletteAPIClientTests`; implementation run must replay them with the generated client. |
| Disk cache and offline fallback stay intact | Existing `ProfileColorCacheTests` cover per-server/profile storage, server-normalized namespaces, and disk round trips. The implementation run must exercise the app-level offline-stale and cached-profile fallback paths. | Existing coverage identified; app-level verification is deferred to implementation because this test-only run cannot change the app seam. |
| Solver remains in parity with `color_matching` | `ParityCorpusTests` replays every vector in `viamin/color_matching@a82aec5441d2a7b0100e8c8ab81d573e11ace9b0:priv/parity/v1/corpus.json`, asserting every score, exclusion, selection, error, and tied index. | Added. |
| Corpus consumption is documented | README names the committed local fixture, upstream source, pin, and refresh command. | Deferred: this red-phase policy allows documentation under `docs/` only; the implementation run must update `README.md`. |
| PR records migration and parity findings | PR body cites generated-client output, API-shape comparison, and executed parity results. | Deferred until an implementation PR exists. |

## Corpus refresh procedure

The committed fixture is copied byte-for-byte from the upstream versioned
corpus. To refresh it, obtain the new upstream corpus and update the pin and
checksum in the implementation PR, then run the parity test. Do not hand-edit
vectors: the upstream generator is the authority.

Current source:

```text
https://raw.githubusercontent.com/viamin/color_matching/a82aec5441d2a7b0100e8c8ab81d573e11ace9b0/priv/parity/v1/corpus.json
SHA-256: 7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604
```
