import json

import numpy as np
import pytest

from Geomag.progress_matching import (
    OnlineMagneticProgressMatcher,
    aggregate_progress_templates,
    align_magnetic_progress,
    load_progress_matcher,
)


def test_online_progress_match_is_causal_and_monotonic():
    matcher = OnlineMagneticProgressMatcher(
        [[0, 0, 0], [1, 0, 0], [2, 1, 0], [3, 1, 1]],
        [0.1, 0.3, 0.6, 0.9],
        transition_penalty=0.5,
    )
    matches = [
        matcher.update(vector)
        for vector in [[10, 5, 1], [11, 5, 1], [12, 6, 1], [13, 6, 2]]
    ]

    assert [item.progress for item in matches] == sorted(
        item.progress for item in matches
    )
    assert matches[-1].template_index >= 2
    assert matches[-1].observation_count == 4


def test_load_progress_matcher_drops_origin_progress(tmp_path):
    path = tmp_path / "template.json"
    path.write_text(
        json.dumps(
            {
                "geomagnetic_vector_history": [
                    [0, 0, 0],
                    [1, 0, 0],
                    [2, 0, 0],
                ],
                "track_progress": [0.0, 0.1, 0.5, 0.9],
            }
        ),
        encoding="utf-8",
    )

    matcher = load_progress_matcher(path)

    assert matcher.template_progress.tolist() == pytest.approx([0.1, 0.5, 0.9])


def test_progress_matcher_rejects_non_monotonic_template():
    with pytest.raises(ValueError, match="monotonic"):
        OnlineMagneticProgressMatcher(
            [[0, 0, 0], [1, 0, 0], [2, 0, 0]],
            [0.0, 0.8, 0.4],
        )


def test_aggregate_progress_templates_resamples_and_rejects_outlier():
    vectors, progress, dispersion = aggregate_progress_templates(
        [
            ([[0, 0, 0], [1, 1, 1], [2, 2, 2]], [0.0, 0.5, 1.0]),
            ([[0, 0, 0], [1, 1, 1], [20, 20, 20], [2, 2, 2]], [0.0, 0.4, 0.6, 1.0]),
            ([[0, 0, 0], [1, 1, 1], [2, 2, 2]], [0.0, 0.5, 1.0]),
        ],
        sample_count=3,
    )

    assert progress.tolist() == pytest.approx([0.0, 0.5, 1.0])
    np.testing.assert_allclose(vectors, [[0, 0, 0], [1, 1, 1], [2, 2, 2]])
    assert dispersion[1].tolist() == pytest.approx([0.0, 0.0, 0.0])


def test_offline_alignment_is_endpoint_constrained_and_bounded():
    reference_progress = np.linspace(0.1, 1.0, 8)
    query_progress = np.asarray([0.08, 0.18, 0.30, 0.45, 0.62, 0.80, 0.92, 1.0])
    reference = np.sin(reference_progress * np.pi * 1.4) * 4.0
    query = np.sin(np.asarray([0.1, 0.22, 0.35, 0.48, 0.60, 0.73, 0.87, 1.0]) * np.pi * 1.4) * 4.0

    alignment = align_magnetic_progress(
        reference,
        reference_progress,
        query,
        query_progress,
        max_gain=0.3,
    )

    assert alignment.accepted
    assert alignment.applied_gain <= 0.3
    assert alignment.progress[-1] == pytest.approx(1.0)
    assert np.all(np.diff(alignment.progress) >= 0.0)
    assert np.max(np.abs(alignment.progress - query_progress)) < 0.15


@pytest.mark.parametrize(
    ("reference", "query", "reason"),
    [
        ([40.0, 41.0, 42.0, 43.0], [40.0, 41.0, 42.0, 43.0], "too_few_samples"),
        ([40.0] * 6, [40.1] * 6, "insufficient_magnetic_variation"),
    ],
)
def test_offline_alignment_rejects_weak_signatures(reference, query, reason):
    progress = np.linspace(0.1, 1.0, len(reference))

    alignment = align_magnetic_progress(
        reference,
        progress,
        query,
        progress,
    )

    assert not alignment.accepted
    assert alignment.reason == reason
    assert alignment.applied_gain == 0.0
    np.testing.assert_allclose(alignment.progress, progress)
