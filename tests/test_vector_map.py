"""Tests for own-data three-axis map reconstruction."""

import numpy as np
import pytest

from Geomag.vector_map import align_vector_line_to_scalar_reference


def test_align_vector_line_selects_reverse_sample_order():
    xyz = np.asarray(
        [
            [1.0, 0.0, 0.0],
            [2.0, 0.0, 0.0],
            [3.0, 0.0, 0.0],
            [4.0, 0.0, 0.0],
        ]
    )
    reference = np.asarray([4.0, 3.0, 2.0, 1.0])

    aligned, diagnostics = align_vector_line_to_scalar_reference(
        xyz, reference
    )

    assert diagnostics["reversed"] is True
    assert aligned[:, 0] == pytest.approx(reference)
    assert diagnostics["selected_correlation"] == pytest.approx(1.0)
