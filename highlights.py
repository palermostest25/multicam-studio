"""Plan non-overlapping energetic clips across an entire recording.

Loudness is a suggestion, not a judgement of the performance. The caller can
review/deselect every range before passing it to the batch exporter.
"""
from __future__ import annotations

import math


def plan_clips(peaks, duration, target_seconds=30, maximum=1):
    import numpy as np
    from scipy.ndimage import uniform_filter1d

    if isinstance(target_seconds, bool):
        raise ValueError('Approximate clip length must be between 2 and 300 seconds.')
    try:
        target = float(target_seconds)
    except (TypeError, ValueError):
        raise ValueError('Approximate clip length must be between 2 and 300 seconds.')
    if not math.isfinite(target) or not 2 <= target <= 300:
        raise ValueError('Approximate clip length must be between 2 and 300 seconds.')
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError('The recording needs a positive duration.')
    values = np.asarray(peaks, dtype=float)
    if values.ndim != 1 or not len(values) or not np.all(np.isfinite(values)):
        return []
    if maximum <= 1e-6 or np.max(values) <= 0:
        return []
    step = duration / len(values)
    smooth = uniform_filter1d(values, size=min(len(values), max(1, round(3 / step))), mode='nearest')
    # Uniform recordings have no distinct energetic moments. In particular, do
    # not turn silence or steady low-level noise into a whole-video highlight.
    if np.ptp(smooth) < .015:
        return []
    threshold = max(float(np.quantile(smooth, .75)), float(np.max(smooth)) * .2)
    hot = smooth >= threshold
    changes = np.diff(np.r_[False, hot, False].astype(int))
    intervals = []
    length = min(target, duration)
    for left, right in zip(np.flatnonzero(changes == 1), np.flatnonzero(changes == -1)):
        # Tiny isolated crossings are unlikely to be a useful musical phrase.
        if (right - left) * step < min(1, length / 4):
            continue
        start, end = max(0, left * step - 1), min(duration, right * step + 1)
        if end - start < length:
            start = max(0, min(duration - length, (start + end - length) / 2))
            end = start + length
        if intervals and start <= intervals[-1][1]:
            intervals[-1][1] = max(end, intervals[-1][1])
        else:
            intervals.append([start, end])
    clips = []
    for start, end in intervals:
        # Split sustained energetic sections instead of truncating their tail.
        # Equal pieces avoid a very short last clip. All regions are retained;
        # there is no 'top 20' cap that would discard the rest of a long set.
        pieces = max(1, math.floor((end - start) / target + .5))
        for index in range(pieces):
            a = start + (end - start) * index / pieces
            b = start + (end - start) * (index + 1) / pieces
            score = float(np.mean(smooth[int(a / step):max(int(a / step) + 1, math.ceil(b / step))]))
            clips.append({'start': round(a, 3), 'end': round(b, 3), 'score': round(score, 3)})
    return clips
