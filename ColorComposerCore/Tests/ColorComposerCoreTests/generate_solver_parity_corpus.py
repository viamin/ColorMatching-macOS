#!/usr/bin/env python3
"""Generates the WeightedSquaredError solver parity corpus fixture.

The corpus is the ground truth `SolverParityCorpusTests.swift` asserts
against: every expected outcome here is computed by this script's
independent reference implementation of the Elixir
`ColorMatching.WeightedSquaredError` scorer and
`IlluminantMatching.best_match/4` selection policy (lowest score wins,
earliest candidate wins ties, missing any positively-weighted condition on
candidate or target excludes the candidate).

Refresh: `python3 generate_solver_parity_corpus.py` (writes
solver_parity_corpus.json next to this script).

Naming convention (enforced below and asserted by the corpus-coverage
test): case ids must contain the markers `doctest`, `zero-weight`,
`excluded`, and `tie` so a truncated or mis-transcribed refresh cannot
silently drop coverage of those parity-relevant behaviors.

When the machine-generated corpus from viamin/color_matching#111 lands it
replaces this fixture wholesale; until then this derivation documents the
exact expected semantics.
"""

import json
import os
import sys

CONDITIONS = ["white", "red", "green", "blue", "lps"]  # LightingCondition.all canonical order


def active(weights):
    return [(c, weights.get(c, 0.0)) for c in CONDITIONS if weights.get(c, 0.0) > 0.0]


def score(candidate, target, weights):
    """Reference WeightedSquaredError: None means excluded."""
    act = active(weights)
    for condition, weight in act:
        if condition not in candidate or condition not in target:
            return None
    total = 0.0
    for condition, weight in act:
        diff = candidate[condition] - target[condition]
        total += diff * diff * weight
    return total


def best_match(palette, cell, weights):
    """Reference IlluminantMatching.best_match/4: strict less-than, earliest wins."""
    best_index, best_score = None, float("inf")
    for index, entry in enumerate(palette):
        result = score(entry["responses"], cell, weights)
        if result is None:
            continue
        if result < best_score:
            best_index, best_score = index, result
    if best_index is None:
        return None, None
    return palette[best_index]["id"], best_score


def solve(palette, cells, weights):
    act = active(weights)
    eligible = [e for e in palette if all(c in e["responses"] for c, _ in act)]
    excluded_count = len(palette) - len(eligible)
    selections, errors, ties = [], [], []
    for cell in cells:
        for condition, _ in act:
            if condition not in cell:
                raise ValueError(f"cell {cell} missing active condition {condition}")
        winner_id, winner_score = best_match(palette, cell, weights)
        selections.append(winner_id)
        errors.append(winner_score)
        ties.append(
            sum(
                1
                for e in palette
                if score(e["responses"], cell, weights) is not None
                and score(e["responses"], cell, weights) == winner_score
            )
            > 1
        )
    return selections, errors, ties, excluded_count


def score_case(case_id, description, weights, candidate, target):
    value = score(candidate, target, weights)
    expected = {"outcome": "excluded"} if value is None else {"outcome": "score", "value": value}
    return {
        "id": case_id,
        "kind": "score",
        "description": description,
        "weights": weights,
        "candidate": candidate,
        "target": target,
        "expected": expected,
    }


def selection_case(case_id, description, weights, palette, cells, grid_width=None, grid_height=None):
    selections, errors, ties, excluded_count = solve(palette, cells, weights)
    case = {
        "id": case_id,
        "kind": "selection",
        "description": description,
        "weights": weights,
        "palette": palette,
        "cells": cells,
        "expected": {
            "selections": selections,
            "errors": errors,
            "ties": ties,
            "excludedCandidateCount": excluded_count,
        },
    }
    if grid_width is not None:
        case["gridWidth"] = grid_width
    if grid_height is not None:
        case["gridHeight"] = grid_height
    return case


def color(entry_id, responses, hex_code=None):
    return {"id": entry_id, "hex": hex_code or "#000000", "responses": responses}


def build_cases():
    cases = []

    # --- score cases -----------------------------------------------------
    cases.append(
        score_case(
            "score-doctest-anchor",
            "The Elixir ColorMatching.WeightedSquaredError doctest: weights "
            "{white: 0.5, red: 1, green: 1, blue: 0, lps: 1.5} must yield 0.205.",
            {"white": 0.5, "red": 1.0, "green": 1.0, "blue": 0.0, "lps": 1.5},
            {"white": 0.5, "red": 0.1, "green": 0.4, "blue": 0.0, "lps": 0.3},
            {"white": 0.8, "red": 0.2, "green": 0.7, "blue": 0.1, "lps": 0.5},
        )
    )
    cases.append(
        score_case(
            "score-exact-match-zero",
            "Identical candidate and target vectors score exactly zero.",
            {"white": 2.0, "red": 1.0},
            {"white": 0.3, "red": 0.7},
            {"white": 0.3, "red": 0.7},
        )
    )
    cases.append(
        score_case(
            "score-zero-weight-ignores-other-channels",
            "Only white is active; candidate/target missing every other "
            "channel must not be excluded and only white contributes.",
            {"white": 1.0, "red": 0.0, "green": 0.0, "blue": 0.0, "lps": 0.0},
            {"white": 0.5},
            {"white": 0.8},
        )
    )
    cases.append(
        score_case(
            "score-zero-weight-missing-channel-not-excluded",
            "Blue carries weight 0 and is missing from both sides; red alone "
            "scores. A naive required-all-channels reading would exclude here.",
            {"red": 1.0, "blue": 0.0},
            {"red": 0.5},
            {"red": 0.3},
        )
    )
    cases.append(
        score_case(
            "score-measured-zero-is-not-missing",
            "White is measured as exactly 0.0 (present) and must contribute "
            "0.0625, not trigger exclusion.",
            {"white": 1.0, "red": 1.0},
            {"white": 0.0, "red": 0.5},
            {"white": 0.25, "red": 0.5},
        )
    )
    cases.append(
        score_case(
            "score-weight-scales-channel-error",
            "Unit diffs on both channels; the channel weight multiplies the "
            "squared contribution (10*1 + 1*1 = 11).",
            {"white": 10.0, "red": 1.0},
            {"white": 0.0, "red": 1.0},
            {"white": 1.0, "red": 0.0},
        )
    )
    cases.append(
        score_case(
            "score-fractional-weights",
            "Fractional weights: 0.25*(-0.25)^2 + 2.0*(0.8)^2 = 1.295625.",
            {"red": 0.25, "green": 2.0},
            {"red": 0.3, "green": 0.9},
            {"red": 0.55, "green": 0.1},
        )
    )
    cases.append(
        score_case(
            "score-all-five-channels-mixed-weights",
            "All five conditions active with distinct weights.",
            {"white": 1.5, "red": 2.0, "green": 0.5, "blue": 1.0, "lps": 3.0},
            {"white": 0.62, "red": 0.11, "green": 0.84, "blue": 0.03, "lps": 0.47},
            {"white": 0.30, "red": 0.72, "green": 0.29, "blue": 0.95, "lps": 0.40},
        )
    )
    cases.append(
        score_case(
            "score-lps-only",
            "LPS-only matching: (0.42-0.58)^2 = 0.0256.",
            {"lps": 1.0},
            {"lps": 0.42},
            {"lps": 0.58},
        )
    )
    cases.append(
        score_case(
            "score-diff-sign-symmetric",
            "Opposite-sign diffs of equal magnitude on equal weights: "
            "0.64 + 0.64 = 1.28.",
            {"red": 1.0, "green": 1.0},
            {"red": 0.9, "green": 0.1},
            {"red": 0.1, "green": 0.9},
        )
    )
    cases.append(
        score_case(
            "score-tiny-weight",
            "Very small weight keeps the score well under 1e-3.",
            {"white": 0.001},
            {"white": 0.25},
            {"white": 0.75},
        )
    )
    cases.append(
        score_case(
            "score-large-weight",
            "Large weight: 100*(0.1)^2 = 1.0.",
            {"white": 100.0},
            {"white": 0.4},
            {"white": 0.5},
        )
    )
    cases.append(
        score_case(
            "excluded-candidate-missing-required-channel",
            "Green has positive weight but the candidate lacks it: excluded.",
            {"red": 1.0, "green": 1.0},
            {"red": 0.5},
            {"red": 0.5, "green": 0.5},
        )
    )
    cases.append(
        score_case(
            "excluded-target-missing-required-channel",
            "Green has positive weight but the target lacks it: excluded.",
            {"red": 1.0, "green": 1.0},
            {"red": 0.5, "green": 0.5},
            {"red": 0.5},
        )
    )

    # --- selection cases -------------------------------------------------
    cases.append(
        selection_case(
            "selection-nearest-wins",
            "Single channel; the nearer brightness wins with its exact error.",
            {"white": 1.0},
            [color(10, {"white": 0.1}), color(11, {"white": 0.8})],
            [{"white": 0.75}],
        )
    )
    # Tie cases deliberately use dyadic values (0.0/0.25/0.5/0.75/1.0) so the
    # equality is exact in IEEE arithmetic, not an ulp-level coincidence that
    # could flip between the Elixir, Python, and Swift summations.
    cases.append(
        selection_case(
            "selection-tie-earliest-palette-order-not-lowest-id",
            "Two candidates exactly equidistant from the target; the earlier "
            "palette entry (id 22) must win over the later one (id 11), "
            "proving ties break on palette order rather than color id.",
            {"white": 1.0},
            [color(22, {"white": 0.0}), color(11, {"white": 1.0})],
            [{"white": 0.5}],
        )
    )
    cases.append(
        selection_case(
            "selection-tie-three-way-first-wins",
            "Three-way tie at exactly 0.0625 (two identical entries plus a "
            "symmetric third); the first palette entry wins.",
            {"white": 1.0},
            [color(5, {"white": 0.25}), color(6, {"white": 0.25}), color(7, {"white": 0.75})],
            [{"white": 0.5}],
        )
    )
    cases.append(
        selection_case(
            "selection-excluded-closer-candidate-skipped",
            "The closest candidate (exact red match) lacks the required green "
            "measurement and is excluded; the fully-measured candidate wins.",
            {"red": 1.0, "green": 1.0},
            [color(10, {"red": 0.5}), color(11, {"red": 0.6, "green": 0.4})],
            [{"red": 0.5, "green": 0.5}],
        )
    )
    cases.append(
        selection_case(
            "selection-excluded-all-candidates-unmatched",
            "Every candidate misses a required measurement; the cell stays "
            "unmatched (null selection, infinite error).",
            {"red": 1.0, "green": 1.0},
            [color(10, {"red": 0.5}), color(11, {"green": 0.5})],
            [{"red": 0.5, "green": 0.5}],
        )
    )
    flip_palette = [color(10, {"red": 0.6, "green": 0.2}), color(11, {"red": 0.4, "green": 0.8})]
    flip_cell = [{"red": 0.55, "green": 0.75}]
    cases.append(
        selection_case(
            "selection-weight-flip-green-heavy",
            "Same palette and target as selection-weight-flip-red-heavy; "
            "reweighting flips the winner to id 11.",
            {"red": 1.0, "green": 1.0},
            flip_palette,
            flip_cell,
        )
    )
    cases.append(
        selection_case(
            "selection-weight-flip-red-heavy",
            "Down-weighting green (0.01) makes id 10's small red error "
            "dominate; the winner flips relative to equal weights.",
            {"red": 1.0, "green": 0.01},
            flip_palette,
            flip_cell,
        )
    )
    cases.append(
        selection_case(
            "selection-grid-cells-independent",
            "A 2x1 grid whose two cells select different colors; each cell "
            "matches independently with its own error.",
            {"red": 1.0},
            [color(10, {"red": 0.1}), color(11, {"red": 0.9})],
            [{"red": 0.0}, {"red": 1.0}],
            grid_width=2,
            grid_height=1,
        )
    )
    cases.append(
        selection_case(
            "selection-multi-channel-mixed-weights",
            "Four candidates over three channels (white/red/lps) with "
            "distinct weights; includes one candidate excluded for a missing "
            "lps measurement.",
            {"white": 0.5, "red": 1.0, "lps": 1.5},
            [
                color(41, {"white": 0.2, "red": 0.8, "lps": 0.5}),
                color(42, {"white": 0.65, "red": 0.15, "lps": 0.2}),
                color(43, {"white": 0.5, "red": 0.5}),  # no lps -> excluded
                color(44, {"white": 0.0, "red": 0.0, "lps": 0.0}),
            ],
            [{"white": 0.4, "red": 0.4, "lps": 0.4}],
        )
    )
    return cases


def validate(cases):
    by_id = {c["id"]: c for c in cases}
    if len(by_id) != len(cases):
        raise ValueError("duplicate case ids")
    joined = " ".join(by_id)
    for marker in ("doctest", "zero-weight", "excluded", "tie"):
        if marker not in joined:
            raise ValueError(f"corpus lost its {marker} coverage marker")
    anchor = by_id["score-doctest-anchor"]
    if anchor["expected"]["outcome"] != "score" or abs(anchor["expected"]["value"] - 0.205) > 1e-12:
        raise ValueError("doctest anchor no longer reproduces the Elixir 0.205 expectation")
    tie_case = by_id["selection-tie-earliest-palette-order-not-lowest-id"]
    if not any(tie_case["expected"]["ties"]):
        raise ValueError("marked tie case is not actually a tie")
    excluded_scores = sum(1 for c in cases if c["kind"] == "score" and c["expected"]["outcome"] == "excluded")
    if excluded_scores < 2:
        raise ValueError("expected at least two excluded score cases")
    return by_id


def main():
    cases = build_cases()
    validate(cases)
    corpus = {
        "version": 1,
        "generator": "generate_solver_parity_corpus.py — reference implementation of the Elixir "
        "ColorMatching.WeightedSquaredError / IlluminantMatching.best_match semantics; to be "
        "replaced by the machine-generated corpus from viamin/color_matching#111",
        "cases": cases,
    }
    out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "solver_parity_corpus.json")
    with open(out_path, "w", encoding="utf-8") as handle:
        json.dump(corpus, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    score_count = sum(1 for c in cases if c["kind"] == "score")
    selection_count = sum(1 for c in cases if c["kind"] == "selection")
    print(f"wrote {out_path}: {score_count} score cases, {selection_count} selection cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
