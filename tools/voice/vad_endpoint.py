"""Python mirror of lib/core/services/vad_endpoint.dart (spec section 4).

Used only for offline tuning on the vServer. The app's implementation is Dart;
scripts/tests/test_vad_endpoint_parity.py keeps both identical through
test/fixtures/vad_endpoint_cases.json. Change both together.
"""
import math
from dataclasses import dataclass

WINDOW_MS = 32
WINDOW_SAMPLES = 512
START_THRESHOLD = 0.5
END_THRESHOLD = 0.35
TAIL_MS = 250


def windows_for(ms):
    return math.ceil(ms / WINDOW_MS)


@dataclass(frozen=True)
class Config:
    pause_ms: int = 1800
    min_speech_ms: int = 250
    pre_roll_ms: int = 300
    max_ms: int = 600000
    no_speech_ms: int = 8000


@dataclass(frozen=True)
class Decision:
    reason: str
    start_window: int
    end_window: int
    at_window: int


class Endpointer:
    def __init__(self, config):
        self.config = config
        self._pause_windows = windows_for(config.pause_ms)
        self._min_speech_windows = windows_for(config.min_speech_ms)
        self._pre_roll_windows = windows_for(config.pre_roll_ms)
        self._tail_windows = windows_for(TAIL_MS)
        self._max_windows = config.max_ms // WINDOW_MS
        self._no_speech_windows = config.no_speech_ms // WINDOW_MS
        self.windows = 0
        self._run = 0
        self._run_start = -1
        self._speech_start = -1
        self._last_speech = -1
        self._silence = 0
        self.decision = None

    def _cut_start(self):
        return max(0, self._speech_start - self._pre_roll_windows)

    def feed(self, p):
        if self.decision is not None:
            return None
        i = self.windows
        self.windows += 1
        if self._speech_start < 0:
            if p >= START_THRESHOLD:
                if self._run == 0:
                    self._run_start = i
                self._run += 1
                if self._run >= self._min_speech_windows:
                    self._speech_start = self._run_start
                    self._last_speech = i
                    self._silence = 0
            elif p < END_THRESHOLD:
                self._run = 0
        elif p >= END_THRESHOLD:
            self._last_speech = i
            self._silence = 0
        else:
            self._silence += 1
            if self._silence >= self._pause_windows:
                end = min(self._last_speech + 1 + self._tail_windows, i + 1)
                self.decision = Decision("pause", self._cut_start(), end, i)
                return self.decision
        if self._speech_start < 0 and self._run == 0 and i + 1 >= self._no_speech_windows:
            self.decision = Decision("noSpeech", 0, 0, i)
            return self.decision
        if i + 1 >= self._max_windows:
            if self._speech_start >= 0:
                self.decision = Decision("maxDuration", self._cut_start(), i + 1, i)
            else:
                self.decision = Decision("noSpeech", 0, 0, i)
            return self.decision
        return None

    def feed_all(self, probabilities):
        for p in probabilities:
            decision = self.feed(p)
            if decision is not None:
                return decision
        return None

    def force_end(self, reason):
        if self.decision is not None:
            return self.decision
        if self.windows == 0:
            self.decision = Decision("noSpeech", 0, 0, 0)
        else:
            start = self._cut_start() if self._speech_start >= 0 else 0
            self.decision = Decision(reason, start, self.windows, self.windows - 1)
        return self.decision
