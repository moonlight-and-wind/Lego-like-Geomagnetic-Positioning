"""Online progress matching against an independently captured route template."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np


def aggregate_progress_templates(templates, *, sample_count=None):
    """Build one robust template from independent surveys of the same route.

    Every survey is first interpolated onto a shared progress axis so a slower
    recording cannot dominate merely because it contains more detected steps.
    The component-wise median then rejects capture-specific magnetic spikes.
    """
    prepared = []
    for template_vectors, template_progress in templates:
        vectors = np.asarray(template_vectors, dtype=float)
        progress = np.asarray(template_progress, dtype=float).reshape(-1)
        if vectors.ndim != 2 or vectors.shape[1] != 3 or vectors.shape[0] < 3:
            raise ValueError("Each template_vectors item must have shape (N, 3), N >= 3.")
        if progress.size != vectors.shape[0]:
            raise ValueError("Each template_progress item must match its vectors length.")
        if not np.all(np.isfinite(vectors)) or not np.all(np.isfinite(progress)):
            raise ValueError("Progress templates must contain only finite values.")
        if np.any(np.diff(progress) < 0.0):
            raise ValueError("Each template_progress item must be monotonic.")
        unique_progress, unique_indices = np.unique(
            np.clip(progress, 0.0, 1.0), return_index=True
        )
        if unique_progress.size < 3:
            raise ValueError("Each progress template must contain three distinct positions.")
        prepared.append((vectors[unique_indices], unique_progress))
    if not prepared:
        raise ValueError("At least one progress template is required.")

    if sample_count is None:
        sample_count = int(round(np.median([item[0].shape[0] for item in prepared])))
    sample_count = max(3, int(sample_count))
    shared_progress = np.linspace(0.0, 1.0, sample_count)
    resampled = []
    for vectors, progress in prepared:
        resampled.append(
            np.column_stack(
                [
                    np.interp(shared_progress, progress, vectors[:, component])
                    for component in range(3)
                ]
            )
        )
    stack = np.stack(resampled, axis=0)
    robust_vectors = np.median(stack, axis=0)
    dispersion = 1.4826 * np.median(
        np.abs(stack - robust_vectors[None, :, :]), axis=0
    )
    return robust_vectors, shared_progress, dispersion


@dataclass
class ProgressMatch:
    progress: float
    template_index: int
    observation_count: int
    normalized_cost: float

    def as_dict(self):
        return {
            "progress": float(self.progress),
            "template_index": int(self.template_index),
            "observation_count": int(self.observation_count),
            "normalized_cost": float(self.normalized_cost),
        }


@dataclass
class MagneticProgressAlignment:
    """Confidence-gated, endpoint-constrained progress alignment result."""

    progress: np.ndarray
    matched_progress: np.ndarray
    accepted: bool
    confidence: float
    applied_gain: float
    correlation: float
    normalized_cost: float
    reference_span: float
    query_span: float
    reason: str

    def as_dict(self):
        return {
            "progress": self.progress.astype(float).tolist(),
            "matched_progress": self.matched_progress.astype(float).tolist(),
            "accepted": bool(self.accepted),
            "confidence": float(self.confidence),
            "applied_gain": float(self.applied_gain),
            "correlation": float(self.correlation),
            "normalized_cost": float(self.normalized_cost),
            "reference_span": float(self.reference_span),
            "query_span": float(self.query_span),
            "reason": self.reason,
        }


def _progress_profile_correlation(
    reference_values,
    reference_progress,
    query_values,
    query_progress,
):
    shared = np.linspace(0.0, 1.0, 64)
    correlations = []
    for component in range(reference_values.shape[1]):
        reference = np.interp(
            shared, reference_progress, reference_values[:, component]
        )
        query = np.interp(shared, query_progress, query_values[:, component])
        if np.std(reference) < 1e-9 or np.std(query) < 1e-9:
            continue
        correlations.append(float(np.corrcoef(reference, query)[0, 1]))
    return float(np.mean(correlations)) if correlations else 0.0


def _endpoint_constrained_dtw(
    reference_values,
    reference_progress,
    query_values,
    *,
    band_ratio,
):
    reference_centered = reference_values - np.mean(reference_values, axis=0)
    query_centered = query_values - np.mean(query_values, axis=0)
    reference_scale = np.maximum(np.std(reference_centered, axis=0), 0.3)
    query_scale = np.maximum(np.std(query_centered, axis=0), 0.3)
    reference_normalized = reference_centered / reference_scale
    query_normalized = query_centered / query_scale
    query_count = query_values.shape[0]
    reference_count = reference_values.shape[0]
    costs = np.full((query_count, reference_count), np.inf, dtype=float)
    previous = np.full((query_count, reference_count, 2), -1, dtype=int)
    for query_index in range(query_count):
        query_fraction = query_index / max(query_count - 1, 1)
        for reference_index in range(reference_count):
            reference_fraction = reference_index / max(reference_count - 1, 1)
            if abs(query_fraction - reference_fraction) > band_ratio:
                continue
            emission = float(
                np.mean(
                    np.square(
                        query_normalized[query_index]
                        - reference_normalized[reference_index]
                    )
                )
            )
            if query_index == 0 and reference_index == 0:
                costs[query_index, reference_index] = emission
                continue
            candidates = []
            if query_index > 0:
                candidates.append(
                    (costs[query_index - 1, reference_index] + 0.08,
                     query_index - 1, reference_index)
                )
            if reference_index > 0:
                candidates.append(
                    (costs[query_index, reference_index - 1] + 0.08,
                     query_index, reference_index - 1)
                )
            if query_index > 0 and reference_index > 0:
                candidates.append(
                    (costs[query_index - 1, reference_index - 1],
                     query_index - 1, reference_index - 1)
                )
            best_cost, previous_query, previous_reference = min(candidates)
            costs[query_index, reference_index] = best_cost + emission
            previous[query_index, reference_index] = (
                previous_query,
                previous_reference,
            )

    if not np.isfinite(costs[-1, -1]):
        raise ValueError("No endpoint-constrained DTW path is available.")
    query_index = query_count - 1
    reference_index = reference_count - 1
    path = []
    while query_index >= 0 and reference_index >= 0:
        path.append((query_index, reference_index))
        previous_query, previous_reference = previous[query_index, reference_index]
        if previous_query < 0:
            break
        query_index, reference_index = previous_query, previous_reference
    path.reverse()
    matched = np.asarray(
        [
            np.mean(
                [
                    reference_progress[reference_index]
                    for path_query, reference_index in path
                    if path_query == query_index
                ]
            )
            for query_index in range(query_count)
        ],
        dtype=float,
    )
    matched = np.maximum.accumulate(matched)
    matched[-1] = 1.0
    normalized_cost = float(costs[-1, -1] / max(len(path), 1))
    return matched, normalized_cost


def align_magnetic_progress(
    reference_values,
    reference_progress,
    query_values,
    query_progress,
    *,
    min_samples=5,
    min_span=1.0,
    min_correlation=0.75,
    max_normalized_cost=0.75,
    max_gain=0.30,
    band_ratio=0.35,
):
    """Align one route leg without allowing magnetics to override its endpoints.

    The matcher is deliberately conservative.  It rejects short or nearly
    constant signatures, constrains DTW to move monotonically from the start
    to the end, and blends only a bounded fraction of the inferred warp into
    the PDR progress.  Rejected matches return the original query progress.
    """
    reference = np.asarray(reference_values, dtype=float)
    query = np.asarray(query_values, dtype=float)
    if reference.ndim == 1:
        reference = reference[:, None]
    if query.ndim == 1:
        query = query[:, None]
    reference_axis = np.asarray(reference_progress, dtype=float).reshape(-1)
    query_axis = np.asarray(query_progress, dtype=float).reshape(-1)
    if (
        reference.ndim != 2
        or query.ndim != 2
        or reference.shape[1] != query.shape[1]
        or reference.shape[0] != reference_axis.size
        or query.shape[0] != query_axis.size
    ):
        raise ValueError("Magnetic values and progress axes have incompatible shapes.")
    if not (
        np.all(np.isfinite(reference))
        and np.all(np.isfinite(query))
        and np.all(np.isfinite(reference_axis))
        and np.all(np.isfinite(query_axis))
    ):
        raise ValueError("Magnetic progress inputs must contain only finite values.")
    if np.any(np.diff(reference_axis) < 0.0) or np.any(np.diff(query_axis) < 0.0):
        raise ValueError("Magnetic progress axes must be monotonic.")
    if reference_axis.size:
        reference_axis = np.clip(reference_axis, 0.0, 1.0)
    if query_axis.size:
        query_axis = np.clip(query_axis, 0.0, 1.0)

    reference_span = float(np.linalg.norm(np.ptp(reference, axis=0)))
    query_span = float(np.linalg.norm(np.ptp(query, axis=0)))
    original = query_axis.copy()
    matched = query_axis.copy()
    correlation = 0.0
    normalized_cost = float("inf")
    reason = "accepted"
    if min(reference.shape[0], query.shape[0]) < int(min_samples):
        reason = "too_few_samples"
    elif min(reference_span, query_span) < float(min_span):
        reason = "insufficient_magnetic_variation"
    else:
        correlation = _progress_profile_correlation(
            reference, reference_axis, query, query_axis
        )
        matched, normalized_cost = _endpoint_constrained_dtw(
            reference,
            reference_axis,
            query,
            band_ratio=float(np.clip(band_ratio, 0.05, 1.0)),
        )
        if correlation < float(min_correlation):
            reason = "low_correlation"
        elif normalized_cost > float(max_normalized_cost):
            reason = "high_alignment_cost"

    accepted = reason == "accepted"
    confidence = 0.0
    gain = 0.0
    if accepted:
        sample_confidence = float(
            np.clip((min(reference.shape[0], query.shape[0]) - 3.0) / 7.0, 0.0, 1.0)
        )
        variation_confidence = float(
            np.clip(min(reference_span, query_span) / (2.0 * min_span), 0.0, 1.0)
        )
        correlation_confidence = float(
            np.clip(
                (correlation - min_correlation) / max(1.0 - min_correlation, 1e-9),
                0.0,
                1.0,
            )
        )
        cost_confidence = float(
            np.clip(1.0 - normalized_cost / max(max_normalized_cost, 1e-9), 0.0, 1.0)
        )
        confidence = float(
            np.sqrt(
                sample_confidence
                * variation_confidence
                * correlation_confidence
                * cost_confidence
            )
        )
        gain = float(np.clip(max_gain, 0.0, 1.0) * confidence)
    corrected = (1.0 - gain) * original + gain * matched
    corrected = np.maximum.accumulate(corrected)
    if corrected.size:
        corrected[-1] = 1.0
    return MagneticProgressAlignment(
        progress=corrected,
        matched_progress=matched,
        accepted=accepted,
        confidence=confidence,
        applied_gain=gain,
        correlation=correlation,
        normalized_cost=normalized_cost,
        reference_span=reference_span,
        query_span=query_span,
        reason=reason,
    )


class OnlineMagneticProgressMatcher:
    """Causal Viterbi/DTW matcher using step-to-step magnetic-vector changes.

    The state is constrained to move forward through the template by at most
    ``max_advance`` samples per observed step.  Only past observations are
    used, so the result can be consumed online.
    """

    def __init__(
        self,
        template_vectors,
        template_progress,
        *,
        max_advance=3,
        transition_penalty=0.5,
        expected_advance=1.0,
    ):
        vectors = np.asarray(template_vectors, dtype=float)
        progress = np.asarray(template_progress, dtype=float).reshape(-1)
        if vectors.ndim != 2 or vectors.shape[0] < 3 or vectors.shape[1] != 3:
            raise ValueError("template_vectors must have shape (N, 3), N >= 3.")
        if progress.size != vectors.shape[0]:
            raise ValueError("template_progress must match template_vectors length.")
        if np.any(np.diff(progress) < 0.0):
            raise ValueError("template_progress must be monotonic.")

        deltas = np.diff(vectors, axis=0, prepend=vectors[:1])
        scale = np.maximum(np.std(deltas[1:], axis=0), 0.5)
        self.template_deltas = deltas / scale
        self.delta_scale = scale
        self.template_progress = np.clip(progress, 0.0, 1.0)
        self.max_advance = max(1, int(max_advance))
        self.transition_penalty = max(0.0, float(transition_penalty))
        self.expected_advance = max(0.0, float(expected_advance))
        self.costs = np.full(vectors.shape[0], np.inf, dtype=float)
        self.costs[0] = 0.0
        self.previous_vector = None
        self.observation_count = 0
        self.committed_index = 0

    def update(self, magnetic_vector):
        vector = np.asarray(magnetic_vector, dtype=float).reshape(-1)
        if vector.size != 3 or not np.all(np.isfinite(vector)):
            raise ValueError("magnetic_vector must contain three finite values.")
        self.observation_count += 1
        if self.previous_vector is None:
            self.previous_vector = vector
            return ProgressMatch(
                progress=float(self.template_progress[0]),
                template_index=0,
                observation_count=self.observation_count,
                normalized_cost=0.0,
            )

        observed_delta = (vector - self.previous_vector) / self.delta_scale
        self.previous_vector = vector
        emissions = np.mean(
            np.square(self.template_deltas - observed_delta[None, :]), axis=1
        )
        updated = np.full_like(self.costs, np.inf)
        for template_index in range(updated.size):
            best = np.inf
            for advance in range(self.max_advance + 1):
                previous_index = template_index - advance
                if previous_index < 0:
                    continue
                transition = self.transition_penalty * (
                    float(advance) - self.expected_advance
                ) ** 2
                best = min(best, self.costs[previous_index] + transition)
            updated[template_index] = best + emissions[template_index]

        minimum = float(np.min(updated))
        if np.isfinite(minimum):
            updated -= minimum
        self.costs = updated
        best_index = int(np.argmin(updated))
        self.committed_index = max(self.committed_index, best_index)
        committed_cost = float(updated[self.committed_index])
        return ProgressMatch(
            progress=float(self.template_progress[self.committed_index]),
            template_index=self.committed_index,
            observation_count=self.observation_count,
            normalized_cost=committed_cost,
        )


def load_progress_matcher(result_json, **kwargs):
    """Load an online matcher from a prior branch result JSON."""

    path = Path(result_json)
    payload = json.loads(path.read_text(encoding="utf-8"))
    vectors = payload.get("geomagnetic_vector_history")
    progress = payload.get("track_progress")
    if vectors is None or progress is None:
        raise ValueError(
            f"Progress template {path} lacks geomagnetic_vector_history or track_progress."
        )
    # track_progress includes the route origin; vector history contains steps only.
    if len(progress) == len(vectors) + 1:
        progress = progress[1:]
    return OnlineMagneticProgressMatcher(vectors, progress, **kwargs)
