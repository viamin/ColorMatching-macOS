# Solver parity fixtures

`solver-parity-v1.json` is copied verbatim from
`viamin/color_matching` at commit
[`a82aec5441d2a7b0100e8c8ab81d573e11ace9b0`](https://github.com/viamin/color_matching/commit/a82aec5441d2a7b0100e8c8ab81d573e11ace9b0),
which implements color_matching#111. The fixture is intentionally read from
the committed test path so parity tests do not depend on the network.

When the upstream solver's `algorithm_version` changes, refresh this file from
`priv/parity/v1/corpus.json` at the reviewed upstream commit, retain the source
commit above (or replace it with the new immutable commit), then run
`cd ColorComposerCore && swift test`.
