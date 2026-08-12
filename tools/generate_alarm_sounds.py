"""Generate deterministic, loop-safe PCM WAV assets for temperature alarms."""

from __future__ import annotations

import math
import struct
import wave
from pathlib import Path


SAMPLE_RATE = 22050
PEAK = 0.92
OUTPUT_DIR = Path(__file__).resolve().parents[1] / "assets" / "audio"


def envelope(position: float, start: float, end: float) -> float:
    """Short cosine attack/release prevents clicks at beep boundaries."""
    fade = min(0.018, (end - start) / 4)
    if position < start or position >= end:
        return 0.0
    if position < start + fade:
        phase = (position - start) / fade
        return 0.5 - 0.5 * math.cos(math.pi * phase)
    if position > end - fade:
        phase = (end - position) / fade
        return 0.5 - 0.5 * math.cos(math.pi * phase)
    return 1.0


def render(
    filename: str,
    duration: float,
    events: list[tuple[float, float, tuple[float, ...]]],
) -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    samples = []
    for index in range(round(duration * SAMPLE_RATE)):
        position = index / SAMPLE_RATE
        value = 0.0
        for start, end, frequencies in events:
            gain = envelope(position, start, end)
            if gain == 0:
                continue
            tone = sum(
                math.sin(2 * math.pi * frequency * position)
                for frequency in frequencies
            ) / len(frequencies)
            value += tone * gain
        value = max(-1.0, min(1.0, value * PEAK))
        samples.append(struct.pack("<h", round(value * 32767)))

    with wave.open(str(OUTPUT_DIR / filename), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(b"".join(samples))


def main() -> None:
    # Fast alternating dual-tone pattern; loudest/default option.
    render(
        "urgent_alarm.wav",
        1.20,
        [
            (0.00, 0.19, (880.0, 1320.0)),
            (0.27, 0.46, (660.0, 990.0)),
            (0.60, 0.79, (880.0, 1320.0)),
            (0.87, 1.06, (660.0, 990.0)),
        ],
    )
    # Familiar high/low electronic beeper with more breathing room.
    render(
        "dual_beep.wav",
        1.40,
        [
            (0.00, 0.24, (760.0,)),
            (0.31, 0.55, (1040.0,)),
            (0.70, 0.94, (760.0,)),
            (1.01, 1.25, (1040.0,)),
        ],
    )
    # Slower low-frequency pulse for quieter monitoring environments.
    render(
        "slow_pulse.wav",
        1.60,
        [
            (0.00, 0.34, (520.0, 780.0)),
            (0.80, 1.14, (520.0, 780.0)),
        ],
    )


if __name__ == "__main__":
    main()
