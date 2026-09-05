#!/usr/bin/env python3
"""Generate pre-recorded ElevenLabs MP3s for the 13 static prompt
phrases the child hears during normal practice.

Why pre-recorded: the user flagged AVSpeechSynthesizer's quality as
robotic, and the system TTS pipeline shares an AVAudioSession with
AVAudioEngine — touching the canvas during a phase entry can cut
the in-flight utterance short (observed: the freeWrite prompt was
clipped on every non-trivial letter). Pre-recorded MP3s played via
AVAudioPlayer (`PrimaeNative/Core/PromptPlayer.swift`) keep the
voice quality high; the cutoff race is mitigated by the shorter
fixed durations of the recorded takes.

Output layout:
    audio_variants/<Voice>/prompts/
        phase_observe.mp3
        phase_direct.mp3
        phase_guided.mp3
        phase_freewrite.mp3
        praise_4.mp3 ... praise_0.mp3
        paper_show.mp3 ... paper_assess.mp3
        retrieval_question.mp3

Voice strategy: we generate every prompt across the same 10 German
voices that `generate_letter_audio.py` uses (so a future researcher
can A/B which voice reads best alongside the letter audio). After
listening, copy a chosen voice's `prompts/` dir into place:

    cp audio_variants/Ela/prompts/*.mp3 \\
       PrimaeNative/Resources/Prompts/

The runtime side reads from
`PrimaeNative/Resources/Prompts/<key>.mp3` via the SPM resource
bundle — `PromptPlayer.PromptKey.rawValue` is the filename stem.

Audition mode (``--prompt phase_freewrite``) generates only that
prompt across every voice — useful for picking a voice without
paying for the full set.

Re-runs skip files that already exist.

Prereq:
    export ELEVENLABS_API_KEY=your-key
    pip install requests
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

try:
    import requests
except ImportError:
    sys.stderr.write("pip install requests\n")
    sys.exit(1)

API_KEY = os.environ.get("ELEVENLABS_API_KEY")
BASE_URL = "https://api.elevenlabs.io/v1"
MODEL_ID = "eleven_multilingual_v2"

# Same voice set as `generate_letter_audio.py` so the prompt audio
# matches the per-letter phoneme audio the child already hears.
VOICE_IDS: dict[str, str] = {
    "Arthur":    "3nMIMZ7RlGwsq1WLgxY3",
    "Sebastian": "qVRpsZJDV29g1CIPzssm",
    "Patrick":   "pxeeCLhOIRDMINyjLxW2",
    "Markus":    "8aPaMtDocayOBFDFyWHp",
    "SamDE":     "XUjIlSlGtOp4c6lq8Lbz",
    "Peter":     "FosrFSJcgFTol7FFvQXU",
    "Ela":       "e3bIMyLemdwvh75g9Vpt",
    "Darinka":   "IPgFCimtGutbaeC6sKnf",
    "Daien":     "9iYBWBbTzTDIt6imiMxp",
    "Kiki":      "VDMfk0qKd9vRmRuG5nND",
}

# Stable, calm voice settings — these are *prompts*, not phonemes,
# so a single take per phrase is enough (no A1/A2/A3 variants).
VOICE_SETTINGS: dict = {
    "stability": 0.55,
    "similarity_boost": 0.80,
    "style": 0.10,
    "use_speaker_boost": True,
}

# Filename stem ⇄ German phrase. Stems must match
# `PromptPlayer.PromptKey.rawValue` (PrimaeNative/Core/PromptPlayer.swift).
PROMPTS: dict[str, str] = {
    # Phase entry
    "phase_observe":   "Pass jetzt gut auf!",
    "phase_direct":    "Tipp die Punkte der Reihe nach an.",
    "phase_guided":    "Fahr die Linie nach.",
    "phase_freewrite": "Und jetzt du alleine.",
    # Praise tiers
    "praise_4": "Wow, das war perfekt! Super gemacht.",
    "praise_3": "Toll gemacht!",
    "praise_2": "Gut gemacht!",
    "praise_1": "Schon gut! Probier's nochmal.",
    "praise_0": "Probier's gleich nochmal.",
    # Paper transfer
    "paper_show":   "Schau dir den Buchstaben gut an.",
    "paper_write":  "Jetzt schreibst du den Buchstaben auf Papier.",
    "paper_assess": "Wie ist dein Buchstabe geworden?",
    # Retrieval prompt
    "retrieval_question": "Welchen Buchstaben hörst du?",
    # Letter-completion celebration (paired with a system success
    # chime in PromptPlayer.playSuccessChime; the voice line is
    # always the same regardless of star count)
    "celebration": "Super gemacht!",
}

OUTPUT_ROOT = Path("audio_variants")


def synthesise(text: str, voice_id: str, out_path: Path) -> int:
    """POST to ElevenLabs TTS. Writes the MP3 to `out_path` unless the
    file already exists. Returns the number of characters billed (0
    when skipped or on failure).
    """
    if out_path.exists():
        return 0
    resp = requests.post(
        f"{BASE_URL}/text-to-speech/{voice_id}",
        headers={"xi-api-key": API_KEY, "Content-Type": "application/json"},
        json={
            "text": text,
            "model_id": MODEL_ID,
            "voice_settings": VOICE_SETTINGS,
        },
        timeout=60,
    )
    if resp.status_code != 200:
        sys.stderr.write(
            f"  ✗ {resp.status_code} for '{text}' ({voice_id}): "
            f"{resp.text[:200]}\n"
        )
        return -1   # distinguishable from "already on disk" (audit 2026-09-04)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(resp.content)
    return len(text)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    parser.add_argument(
        "--prompt",
        help="Generate only this prompt key (e.g. 'phase_freewrite') "
             "across every voice. Useful for auditioning before "
             "committing spend on the full set.",
    )
    parser.add_argument(
        "--voice",
        help="Generate only this voice (e.g. 'Ela'). Combine with "
             "--prompt for the smallest possible audition.",
    )
    args = parser.parse_args()

    if not API_KEY:
        sys.stderr.write(
            "ELEVENLABS_API_KEY not set. Export it before running.\n"
        )
        return 1

    if args.prompt and args.prompt not in PROMPTS:
        sys.stderr.write(
            f"Unknown prompt key '{args.prompt}'. Known keys:\n"
        )
        for k in PROMPTS:
            sys.stderr.write(f"  {k}\n")
        return 2

    if args.voice and args.voice not in VOICE_IDS:
        sys.stderr.write(
            f"Unknown voice '{args.voice}'. Known voices: "
            f"{', '.join(VOICE_IDS)}\n"
        )
        return 3

    voices = (
        {args.voice: VOICE_IDS[args.voice]} if args.voice else VOICE_IDS
    )
    prompts = (
        {args.prompt: PROMPTS[args.prompt]} if args.prompt else PROMPTS
    )

    total_chars = 0
    failures = 0
    for voice_name, voice_id in voices.items():
        print(f"\n=== {voice_name} ===")
        for stem, text in prompts.items():
            out = OUTPUT_ROOT / voice_name / "prompts" / f"{stem}.mp3"
            chars = synthesise(text, voice_id, out)
            if chars < 0:
                failures += 1
                tag = "FAIL"
            else:
                total_chars += chars
                tag = "·" if chars == 0 else f"+{chars:>3}c"
            print(f"  {tag}  {stem:22}  {text}")

    print(f"\n{total_chars} characters billed in this run.")
    if failures:
        # A run with an expired key used to read exactly like a cached
        # no-op and exit 0 (audit 2026-09-04).
        print(f"{failures} request(s) FAILED — do not copy this output into the app.", file=sys.stderr)
        return 1
    print(f"Output: {OUTPUT_ROOT.resolve()}")
    print(
        "After listening, copy your chosen voice's prompts/ dir into "
        "PrimaeNative/Resources/Prompts/:\n"
        "  cp audio_variants/<Voice>/prompts/*.mp3 "
        "PrimaeNative/Resources/Prompts/"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
