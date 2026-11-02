import Foundation

/// A committed corpus snapshot that pins the parity contract in corpus form
/// even before the upstream corpus from viamin/color_matching#111 is vendored
/// (and independently of it). It follows the exact schema the loader accepts,
/// so it doubles as a live example of the format.
///
/// Every tie case uses exact binary fractions (0.25 / 0.5 / 0.75 / 0.125 …)
/// so the ties are bit-exact in IEEE 754 doubles and cannot pass by luck of
/// rounding. The one exception is `01_elixir_doctest_reference`, which
/// reproduces the published Elixir `WeightedSquaredError` doctest values and
/// score (0.205, compared within 1e-9).
enum ParityCorpusFixture {
    static let json = """
    {
      "version": 1,
      "source": "fixture snapshot; the vendored corpus from viamin/color_matching#111 supersedes it",
      "cases": [
        {
          "name": "01_elixir_doctest_reference",
          "description": "The WeightedSquaredError doctest from color_matching: weights white 0.5, red 1, green 1, lps 1.5 reproduce the documented score 0.205.",
          "weights": { "white": 0.5, "red": 1.0, "green": 1.0, "lps": 1.5 },
          "palette": [
            { "id": 1, "name": "doctest candidate", "hex": "#6b5f52",
              "responses": { "white": 0.5, "red": 0.1, "green": 0.4, "lps": 0.3 } }
          ],
          "target": { "white": 0.8, "red": 0.2, "green": 0.7, "lps": 0.5 },
          "expected": { "selected_id": 1, "score": 0.205, "tie_ids": [1], "excluded_ids": [] }
        },
        {
          "name": "02_exact_tie_breaks_to_earliest_candidate",
          "description": "0.25 and 0.75 under red are equidistant from target 0.5 (exact binary fractions, so the tie is bit-exact); palette order decides.",
          "weights": { "red": 1.0 },
          "palette": [
            { "id": 1, "name": "shadow", "hex": "#404040", "responses": { "red": 0.25 } },
            { "id": 2, "name": "highlight", "hex": "#bfbfbf", "responses": { "red": 0.75 } },
            { "id": 3, "name": "far", "hex": "#000000", "responses": { "red": 0.0 } }
          ],
          "target": { "red": 0.5 },
          "expected": { "selected_id": 1, "score": 0.0625, "tie_ids": [1, 2], "excluded_ids": [] }
        },
        {
          "name": "03_tie_across_swapped_channels",
          "description": "Mirrored response vectors tie exactly under equal red/green weights; the earliest candidate wins.",
          "weights": { "red": 1.0, "green": 1.0 },
          "palette": [
            { "id": 1, "name": "red shadow green highlight", "hex": "#40bf40",
              "responses": { "red": 0.25, "green": 0.75 } },
            { "id": 2, "name": "red highlight green shadow", "hex": "#bf40bf",
              "responses": { "red": 0.75, "green": 0.25 } }
          ],
          "target": { "red": 0.5, "green": 0.5 },
          "expected": { "selected_id": 1, "score": 0.125, "tie_ids": [1, 2], "excluded_ids": [] }
        },
        {
          "name": "04_missing_required_channel_excludes_best_match",
          "description": "Candidate 1 matches red exactly but has no green measurement; green has weight 1 so it is excluded and the measured runner-up is selected. Missing is never zero.",
          "weights": { "red": 1.0, "green": 1.0 },
          "palette": [
            { "id": 1, "name": "red exact green unmeasured", "hex": "#ff0000", "responses": { "red": 0.5 } },
            { "id": 2, "name": "measured neighbor", "hex": "#808080",
              "responses": { "red": 0.5, "green": 0.625 } }
          ],
          "target": { "red": 0.5, "green": 0.5 },
          "expected": { "selected_id": 2, "score": 0.015625, "tie_ids": [2], "excluded_ids": [1] }
        },
        {
          "name": "05_zero_weight_channel_is_not_required",
          "description": "blue has weight 0, so a candidate without a blue measurement stays eligible; only red influences the score.",
          "weights": { "red": 1.0, "blue": 0.0 },
          "palette": [
            { "id": 1, "name": "no blue measurement", "hex": "#400000", "responses": { "red": 0.5 } },
            { "id": 2, "name": "fully measured", "hex": "#000040",
              "responses": { "red": 0.75, "blue": 0.9 } }
          ],
          "target": { "red": 0.5, "blue": 0.9 },
          "expected": { "selected_id": 1, "score": 0.0, "tie_ids": [1], "excluded_ids": [] }
        },
        {
          "name": "06_white_heavy_weights_prefer_white_exact_candidate",
          "description": "Candidate 2 is exact on white and far on red; under white-heavy weights it wins despite candidate 1 being red-exact.",
          "weights": { "white": 4.0, "red": 1.0 },
          "palette": [
            { "id": 1, "name": "red exact white far", "hex": "#ff4040",
              "responses": { "white": 0.25, "red": 0.75 } },
            { "id": 2, "name": "white exact red far", "hex": "#40ff40",
              "responses": { "white": 0.75, "red": 0.25 } }
          ],
          "target": { "white": 0.75, "red": 0.75 },
          "expected": { "selected_id": 2, "score": 0.25, "tie_ids": [2], "excluded_ids": [] }
        },
        {
          "name": "07_red_heavy_weights_flip_to_red_exact_candidate",
          "description": "Same palette and target as case 06 with weights swapped; selection flips to the red-exact candidate.",
          "weights": { "white": 1.0, "red": 4.0 },
          "palette": [
            { "id": 1, "name": "red exact white far", "hex": "#ff4040",
              "responses": { "white": 0.25, "red": 0.75 } },
            { "id": 2, "name": "white exact red far", "hex": "#40ff40",
              "responses": { "white": 0.75, "red": 0.25 } }
          ],
          "target": { "white": 0.75, "red": 0.75 },
          "expected": { "selected_id": 1, "score": 0.25, "tie_ids": [1], "excluded_ids": [] }
        },
        {
          "name": "08_exact_match_scores_zero",
          "description": "A candidate reproducing the full target vector scores exactly zero.",
          "weights": { "red": 1.0, "green": 1.0 },
          "palette": [
            { "id": 1, "name": "exact", "hex": "#3f7f3f",
              "responses": { "red": 0.5, "green": 0.25 } },
            { "id": 2, "name": "off", "hex": "#7f3f3f",
              "responses": { "red": 0.25, "green": 0.5 } }
          ],
          "target": { "red": 0.5, "green": 0.25 },
          "expected": { "selected_id": 1, "score": 0.0, "tie_ids": [1], "excluded_ids": [] }
        },
        {
          "name": "09_fractional_lps_weight_amplifies_channel_error",
          "description": "A 1.5 LPS weight scales that channel's squared error (1.5 x 0.0625 = 0.09375), letting the red-exact candidate lose to the LPS-exact one.",
          "weights": { "red": 1.0, "lps": 1.5 },
          "palette": [
            { "id": 1, "name": "red exact lps off", "hex": "#7f4040",
              "responses": { "red": 0.5, "lps": 0.25 } },
            { "id": 2, "name": "red off lps exact", "hex": "#407f40",
              "responses": { "red": 0.25, "lps": 0.5 } }
          ],
          "target": { "red": 0.5, "lps": 0.5 },
          "expected": { "selected_id": 2, "score": 0.0625, "tie_ids": [2], "excluded_ids": [] }
        },
        {
          "name": "10_all_candidates_excluded_leaves_target_unmatched",
          "description": "Every candidate is missing a required measurement, so nothing is selectable and the cell stays unmatched.",
          "weights": { "red": 1.0, "green": 1.0 },
          "palette": [
            { "id": 1, "name": "red only", "hex": "#ff0000", "responses": { "red": 0.5 } },
            { "id": 2, "name": "green only", "hex": "#00ff00", "responses": { "green": 0.5 } }
          ],
          "target": { "red": 0.5, "green": 0.5 },
          "expected": { "selected_id": null, "score": null, "tie_ids": [], "excluded_ids": [1, 2] }
        },
        {
          "name": "11_measured_zero_brightness_is_not_missing",
          "description": "A measured 0.0 is a real value: the measured-black candidate wins against mid gray for a dark target.",
          "weights": { "red": 1.0 },
          "palette": [
            { "id": 1, "name": "measured black", "hex": "#000000", "responses": { "red": 0.0 } },
            { "id": 2, "name": "mid gray", "hex": "#808080", "responses": { "red": 0.5 } }
          ],
          "target": { "red": 0.0 },
          "expected": { "selected_id": 1, "score": 0.0, "tie_ids": [1], "excluded_ids": [] }
        }
      ]
    }
    """

    static func decode() throws -> ParityCorpus {
        try ParityCorpus.decode(from: Data(json.utf8))
    }
}
