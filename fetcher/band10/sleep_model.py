"""Normalized sleep data model — the contract between the Python fetcher and
the iOS HealthKit writer.

The fetcher emits JSON in this shape; the iOS app reads it and writes one
HKCategorySample per stage segment (plus quantity samples for HR/SpO2/etc).

JSON schema (one object per night):

{
  "version": 1,
  "source": "xiaomi-band10",
  "nights": [
    {
      "date": "2026-06-07",            # local night the sleep belongs to
      "timezone": "Europe/Rome",
      "start": 1717800000,             # epoch seconds, session start (in bed)
      "end":   1717828800,             # epoch seconds, session end
      "score": 86,                     # sleep score, optional
      "stages": [
        {"start": 1717800000, "end": 1717801200, "stage": "awake"},
        {"start": 1717801200, "end": 1717804800, "stage": "light"},
        {"start": 1717804800, "end": 1717807200, "stage": "deep"},
        {"start": 1717807200, "end": 1717809000, "stage": "rem"}
      ],
      "heart_rate":  [{"t": 1717800600, "bpm": 58}, ...],     # optional
      "spo2":        [{"t": 1717800600, "pct": 96}, ...],     # optional
      "hrv":         [{"t": 1717800600, "ms": 42}, ...],      # optional (SDNN)
      "respiratory": [{"t": 1717800600, "brpm": 14}, ...]     # optional
    }
  ]
}

Stage vocabulary (maps cleanly to HKCategoryValueSleepAnalysis on iOS):
  "awake" -> .awake
  "light" -> .asleepCore       (HealthKit has no separate "light")
  "deep"  -> .asleepDeep
  "rem"   -> .asleepREM
  "unknown" -> .asleepUnspecified
"""

from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Any


# Maps Xiaomi/Huami numeric "mode" codes -> our stage vocabulary.
# Confirmed from legacy huami schema: 4 = light, 5 = deep.
# REM / awake codes for the Band 10 are TBD — fill in after inspecting real data.
MODE_TO_STAGE: dict[int, str] = {
    4: "light",
    5: "deep",
    # 6 / 7: candidates for rem / awake — VERIFY against Mi Fitness app display.
    7: "rem",
    8: "awake",
}


@dataclass
class Stage:
    start: int
    end: int
    stage: str  # awake | light | deep | rem | unknown


@dataclass
class Sample:
    t: int


@dataclass
class Night:
    date: str
    timezone: str
    start: int
    end: int
    stages: list[Stage] = field(default_factory=list)
    score: int | None = None
    heart_rate: list[dict[str, Any]] = field(default_factory=list)
    spo2: list[dict[str, Any]] = field(default_factory=list)
    hrv: list[dict[str, Any]] = field(default_factory=list)
    respiratory: list[dict[str, Any]] = field(default_factory=list)


@dataclass
class SleepExport:
    nights: list[Night] = field(default_factory=list)
    version: int = 1
    source: str = "xiaomi-band10"

    def to_dict(self) -> dict[str, Any]:
        return {
            "version": self.version,
            "source": self.source,
            "nights": [asdict(n) for n in self.nights],
        }


def stage_from_mode(mode: int) -> str:
    return MODE_TO_STAGE.get(mode, "unknown")
