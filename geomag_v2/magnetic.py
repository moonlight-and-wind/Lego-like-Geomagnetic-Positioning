"""Bounded magnetic sequence alignment.

Magnetic matching may correct progress within a straight segment, but is not
allowed to change the segment length or teleport a point onto map geometry.
"""

from __future__ import annotations

import numpy as np


def _resample(values: np.ndarray, samples: int) -> np.ndarray:
    values = np.asarray(values, dtype=float)
    if values.shape[0] == samples:
        return values.copy()
    source = np.linspace(0.0, 1.0, values.shape[0])
    target = np.linspace(0.0, 1.0, samples)
    return np.column_stack(
        [np.interp(target, source, values[:, column]) for column in range(values.shape[1])]
    )


def bounded_magnetic_progress(
    template_vectors: np.ndarray,
    query_vectors: np.ndarray,
    inertial_progress: np.ndarray,
    *,
    maximum_correction: float = 0.15,
    magnetic_weight: float = 0.35,
) -> np.ndarray:
    """Return monotonic progress using DTW with a bounded inertial correction."""
    query = np.asarray(query_vectors, dtype=float)
    inertial = np.asarray(inertial_progress, dtype=float)
    if query.shape[0] != inertial.size or query.shape[1] != 3:
        raise ValueError("Query magnetic vectors and inertial progress are misaligned.")
    sample_count = int(np.clip(query.shape[0] // 8, 24, 160))
    template = _resample(np.asarray(template_vectors, dtype=float), sample_count)
    reduced_query = _resample(query, sample_count)
    center = np.median(template, axis=0)
    scale = np.std(template, axis=0)
    scale[scale < 1.0] = 1.0
    template = (template - center) / scale
    reduced_query = (reduced_query - center) / scale

    n = sample_count
    cost = np.full((n, n), np.inf)
    parent = np.full((n, n), -1, dtype=np.int8)
    query_prior = np.linspace(0.0, 1.0, n)
    template_progress = np.linspace(0.0, 1.0, n)
    for i in range(n):
        for j in range(n):
            local = float(np.linalg.norm(reduced_query[i] - template[j]))
            local += 0.35 * abs(query_prior[i] - template_progress[j])
            if i == 0 and j == 0:
                cost[i, j] = local
                continue
            choices = []
            if i > 0:
                choices.append((cost[i - 1, j], 0))
            if j > 0:
                choices.append((cost[i, j - 1], 1))
            if i > 0 and j > 0:
                choices.append((cost[i - 1, j - 1], 2))
            best_cost, best_parent = min(choices, key=lambda item: item[0])
            cost[i, j] = local + best_cost
            parent[i, j] = best_parent

    mapping: list[list[int]] = [[] for _ in range(n)]
    i = j = n - 1
    while i >= 0 and j >= 0:
        mapping[i].append(j)
        direction = parent[i, j]
        if i == 0 and j == 0:
            break
        if direction == 0:
            i -= 1
        elif direction == 1:
            j -= 1
        else:
            i -= 1
            j -= 1
    matched = np.asarray(
        [np.mean(indices) / (n - 1) if indices else query_prior[index] for index, indices in enumerate(mapping)]
    )
    matched = np.maximum.accumulate(matched)
    matched = np.interp(inertial, query_prior, matched)
    bounded = np.clip(matched, inertial - maximum_correction, inertial + maximum_correction)
    fused = (1.0 - magnetic_weight) * inertial + magnetic_weight * bounded
    fused = np.maximum.accumulate(np.clip(fused, 0.0, 1.0))
    fused[0] = 0.0
    fused[-1] = 1.0
    return fused
