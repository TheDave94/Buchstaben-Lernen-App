#!/usr/bin/env python3
"""Generate letter-phoneme + example-word + tracing-word audio for German
using ten popular ElevenLabs voices. Builds the whole audio inventory
the app needs so word-tracing can ship as a full feature, not just a demo.

The per-letter audio is the *phoneme* (the sound the letter makes when
reading), not the letter's name — Austrian Volksschule 1. Klasse teaches
reading via Anlauttabelle, so "M" is spoken "mmmmmh", not "Em", and "T"
is "tttttt", not "Teh". This matches how a first-grade teacher models
blending (m-a-m-a → "Mama") rather than spelling.

Output layout (one folder per voice):
    audio_variants/<Voice>/<Letter>/
        <Letter>1.mp3  – first variant of the phoneme
        <Letter>2.mp3  – second variant
        <Letter>3.mp3  – third variant (three variants match the
                         existing A1/A2/A3 pattern in the bundle so
                         the two-finger-swipe sound cycler keeps working)
        <ExampleWord>.mp3 × 1–2 (Affe.mp3, Alarm.mp3, ...)
    audio_variants/<Voice>/words/
        <TracingWord>.mp3 × ~30 (OMA.mp3, MAMA.mp3, AUTO.mp3, ...)

Variant strategy: each variant hits the API with the same text but
different voice_settings so ElevenLabs returns audibly distinct takes
instead of near-duplicate outputs from same-seed generation.

Budget (Starter tier = 30 000 characters/month):
    per voice:
      - phonemes × 3 variants: 30 letters × ~22 chars × 3 ≈ 1 980
      - example words (~2 per letter, ~6 chars): ≈ 360
      - tracing words (~32 words × ~5 chars):    ≈ 160
      = ~2 500 chars per voice
    × 9 voices = ~22 500 chars, still inside the Starter cap with
    headroom for a couple of re-runs per voice.

Prereq:
    export ELEVENLABS_API_KEY=your-key
    pip install requests

Run:
    python3 scripts/generate_letter_audio.py                 # full inventory
    python3 scripts/generate_letter_audio.py --letter M      # audition mode

Audition mode (``--letter M``) generates only the 3 phoneme variants
for that single letter across every voice — no example words, no
tracing words. Use this first to pick a favourite voice before
committing spend to the full inventory.

Re-runs skip files that already exist, so tweaking one voice/letter
doesn't re-pay for the rest.

After listening, pick a favourite voice and copy its folder into place:
    cp -r audio_variants/Rachel/A/* BuchstabenNative/Resources/Letters/A/
The file names already match what the app expects (A1.mp3 etc.).
"""
from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

try:
    import requests
except ImportError:
    sys.stderr.write("pip install requests\n")
    sys.exit(1)

API_KEY = os.environ.get("ELEVENLABS_API_KEY")

BASE_URL = "https://api.elevenlabs.io/v1"
MODEL_ID = "eleven_multilingual_v2"

# Ten ElevenLabs voices verified for German on eleven_multilingual_v2.
# Picked via /v1/shared-voices?language=de filtered to voices whose
# verified_languages array contains {language: "de", model_id:
# "eleven_multilingual_v2"}. This is the authoritative list — picking
# voices outside it produces an English speaker reading German
# phonetically, because on multilingual_v2 the accent is baked into
# the voice (language_code is silently ignored on this model).
# Tilt: narrative / educational / calm, with gender variety and one
# Austrian-accent voice for project relevance.
VOICE_IDS: dict[str, str] = {
    # Male
    "Arthur":    "3nMIMZ7RlGwsq1WLgxY3",  # confident, educational narrator
    "Sebastian": "qVRpsZJDV29g1CIPzssm",  # calm, conversational
    "Patrick":   "pxeeCLhOIRDMINyjLxW2",  # calm, narrative
    "Markus":    "8aPaMtDocayOBFDFyWHp",  # professional, deep
    "SamDE":     "XUjIlSlGtOp4c6lq8Lbz",  # calm, cozy/warm narrator
    "Peter":     "FosrFSJcgFTol7FFvQXU",  # Austrian/Bavarian accent
    # Female
    "Ela":       "e3bIMyLemdwvh75g9Vpt",  # calm, narrative
    "Darinka":   "IPgFCimtGutbaeC6sKnf",  # warm, professional
    "Daien":     "9iYBWBbTzTDIt6imiMxp",  # pleasant, narrative
    "Kiki":      "VDMfk0qKd9vRmRuG5nND",  # professional narrator
}

# Three voice-settings presets drive audibly different takes from the
# same text, matching the app's A1/A2/A3 variant slots.
VARIANT_SETTINGS: list[dict] = [
    {"stability": 0.35, "similarity_boost": 0.80, "style": 0.30, "use_speaker_boost": True},
    {"stability": 0.55, "similarity_boost": 0.75, "style": 0.15, "use_speaker_boost": True},
    {"stability": 0.75, "similarity_boost": 0.90, "style": 0.00, "use_speaker_boost": True},
]

# German letter *phonemes* — the sustained/repeated sound a first-grade
# teacher models so children learn to blend (m-a-m-a → "Mama") instead
# of spelling ("Em-Ah-Em-Ah"). Sustainable sounds (m, n, l, s, f, …) get
# written out as repeated letters so the TTS holds the sound; plosives
# (b, d, g, k, p, t) can't really be sustained, so repeated characters
# produce a staccato burst — the closest TTS can get to the percussive
# "t-t-t-t" a teacher makes. Vowels trail into an "h" to cue length.
# Spellings are deliberately German-orthography-shaped so the
# multilingual_v2 model reads them in a German voice.
#
# Target duration ~3 s per phoneme. ElevenLabs has no duration knob, so
# we steer length by character count. ~22 chars of a sustained sound
# lands ~2.5–3 s on a typical voice; plosives produce a rapid train of
# bursts over similar wall-time.
LETTER_PHONEMES: dict[str, str] = {
    "A": "Aaaaaaaaaaaaaaaaaaaaah",
    "B": "Bbbbbbbbbbbbbbbbbbbbbb",
    "C": "Tssssssssssssssssssss",
    "D": "Dddddddddddddddddddddd",
    "E": "Eeeeeeeeeeeeeeeeeeeeeh",
    "F": "Fffffffffffffffffffffff",
    "G": "Gggggggggggggggggggggg",
    "H": "Hhhhhhhhhhhhhhhhhhhhhh",
    "I": "Iiiiiiiiiiiiiiiiiiiiih",
    "J": "Jjjjjjjjjjjjjjjjjjjjjj",
    "K": "Kkkkkkkkkkkkkkkkkkkkkk",
    "L": "Lllllllllllllllllllllll",
    "M": "Mmmmmmmmmmmmmmmmmmmmmh",
    "N": "Nnnnnnnnnnnnnnnnnnnnnh",
    "O": "Oooooooooooooooooooooh",
    "P": "Pppppppppppppppppppppp",
    "Q": "Kuuuuuuuuuuuuuuuuuuuuh",
    "R": "Rrrrrrrrrrrrrrrrrrrrrrr",
    "S": "Sssssssssssssssssssssss",
    "T": "Tttttttttttttttttttttt",
    "U": "Uuuuuuuuuuuuuuuuuuuuuh",
    "V": "Fffffffffffffffffffffff",
    "W": "Wwwwwwwwwwwwwwwwwwwwwww",
    "X": "Ksksksksksksksksksksks",
    "Y": "Üüüüüüüüüüüüüüüüüüüüüh",
    "Z": "Tssssssssssssssssssss",
    "Ä": "Äääääääääääääääääääääh",
    "Ö": "Öööööööööööööööööööööh",
    "Ü": "Üüüüüüüüüüüüüüüüüüüüüh",
    "ß": "Ssssssssssssssssssssssh",
}

# Classic Austrian Fibel Anlaut-Tabelle example words — words that start
# with the letter, used for "A wie Affe" hint audio in the single-letter
# flow. Adjust freely; strings here are literally what the TTS reads.
EXAMPLE_WORDS: dict[str, list[str]] = {
    "A": ["Affe", "Alarm"],
    "B": ["Ball", "Baum"],
    "C": ["Clown"],
    "D": ["Dose", "Dach"],
    "E": ["Elefant", "Esel"],
    "F": ["Fisch", "Frosch"],
    "G": ["Giraffe", "Gabel"],
    "H": ["Haus", "Hund"],
    "I": ["Igel", "Insel"],
    "J": ["Jäger"],
    "K": ["Katze", "Kuh"],
    "L": ["Lama", "Löwe"],
    "M": ["Maus", "Mond"],
    "N": ["Nase", "Nuss"],
    "O": ["Oma", "Opa"],
    "P": ["Papa", "Puppe"],
    "Q": ["Quelle"],
    "R": ["Rabe", "Roller"],
    "S": ["Sonne", "Seife"],
    "T": ["Tasse", "Tiger"],
    "U": ["Uhr", "Uhu"],
    "V": ["Vogel", "Vase"],
    "W": ["Wolke", "Wasser"],
    "X": ["Xylophon"],
    "Y": ["Yoga"],
    "Z": ["Zebra", "Zug"],
    "Ä": ["Ärztin"],
    "Ö": ["Öl"],
    "Ü": ["Übung"],
    "ß": [],  # eszett never starts a word
}

# Austrian Volksschule 1. Klasse tracing-word progression — the words a
# first-grader actually composes during the letter-building weeks. Sourced
# from BMBWF Lehrplan Deutsch-oriented primers (Funkelsteine, Mimi die
# Lesemaus AT, Auer Fibel). Ordered roughly shortest → longest so a
# teacher can pick an age-appropriate slice.
TRACING_WORDS: list[str] = [
    # Family (Woche 1)
    "OMA", "OMI", "OPA", "MAMA", "PAPA",
    # Short 3-letter concretes (Woche 2–3)
    "OHR", "UHR", "UHU", "KUH",
    # 4-letter everyday nouns (Woche 3–4)
    "AFFE", "AUTO", "BALL", "HAUS", "MOND", "ROSE",
    "NASE", "OBST", "IGEL", "ESEL", "MAUS",
    "LAMA", "KILO", "FILM",
    # Doubled-letter reinforcement (Woche 4–5)
    "SONNE", "TASSE", "PUPPE", "KATZE", "WOLLE",
    # Longer 5–6 letter (Woche 6+)
    "APFEL", "FISCH", "VOGEL", "SCHULE",
    "FAMILIE", "ELEFANT",
]

OUTPUT_ROOT = Path("audio_variants")


# Failed requests, so a run with an expired key cannot read like a fully
# cached no-op and exit 0 (audit 2026-09-04).
FAILED_REQUESTS: list[str] = []


def synthesise(text: str, voice_id: str, settings: dict, out_path: Path) -> int:
    """POST to ElevenLabs TTS. Writes the MP3 to ``out_path`` unless the
    file already exists. Returns the number of characters billed (0 when
    skipped or on failure).

    On ``eleven_multilingual_v2`` the accent comes *entirely* from the
    voice — there is no language-enforcement parameter (``language_code``
    only works on turbo_v2_5/flash_v2_5; on multilingual_v2 it is
    silently ignored per ElevenLabs team response in elevenlabs-python
    issue #149). So the only way to get a German accent is to use a
    voice whose ``verified_languages`` entry includes
    ``{"language": "de", "model_id": "eleven_multilingual_v2"}``.
    Run this script with ``--list-voices`` to discover such voices
    against the current API.
    """
    if out_path.exists():
        return 0
    resp = requests.post(
        f"{BASE_URL}/text-to-speech/{voice_id}",
        headers={"xi-api-key": API_KEY, "Content-Type": "application/json"},
        json={
            "text": text,
            "model_id": MODEL_ID,
            "voice_settings": settings,
        },
        timeout=60,
    )
    if resp.status_code != 200:
        sys.stderr.write(
            f"  ✗ {resp.status_code} for '{text}' ({voice_id}): "
            f"{resp.text[:200]}\n"
        )
        FAILED_REQUESTS.append(f"{text} ({voice_id})")   # audit 2026-09-04
        return 0
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(resp.content)
    return len(text)


def list_german_voices() -> int:
    """Query the authenticated shared-voices endpoint for voices that
    ElevenLabs has verified as producing a proper German accent on
    the current ``MODEL_ID``. Prints them as a ready-to-paste
    ``VOICE_IDS`` dict. This is the only reliable way to pick German
    voices — browsing third-party directories (e.g. json2video.com)
    often surfaces voices labelled "German" that are not actually
    verified for ``multilingual_v2``; they sound like an English
    speaker reading German phonetically.
    """
    resp = requests.get(
        f"{BASE_URL}/shared-voices",
        headers={"xi-api-key": API_KEY},
        params={"language": "de", "page_size": 100},
        timeout=30,
    )
    if resp.status_code != 200:
        sys.stderr.write(
            f"List failed: {resp.status_code} {resp.text[:300]}\n"
        )
        return 1
    voices = resp.json().get("voices", [])
    print(f"# Found {len(voices)} voices with German in verified_languages.")
    print(f"# Filtering to those verified on model '{MODEL_ID}'.")
    print()

    eligible: list[tuple[dict, dict]] = []
    for v in voices:
        for entry in v.get("verified_languages", []):
            if entry.get("language") == "de" and entry.get("model_id") == MODEL_ID:
                eligible.append((v, entry))
                break

    if not eligible:
        sys.stderr.write(
            f"No voices verified for German on {MODEL_ID}. Try switching "
            f"MODEL_ID to 'eleven_v3' (alpha, highest quality) or "
            f"'eleven_flash_v2_5' (supports language_code enforcement).\n"
        )
        return 2

    print(f"# {len(eligible)} verified for {MODEL_ID}. Paste into VOICE_IDS:")
    print()
    print("VOICE_IDS: dict[str, str] = {")
    for v, entry in eligible[:15]:
        raw_name = v.get("name") or "Voice"
        # Strip trailing " - Descriptor" and non-alphanumerics so the
        # name is safe as a folder under audio_variants/<Voice>/.
        key = raw_name.split(" -")[0].split(" ")[0]
        key = "".join(c for c in key if c.isalnum())[:20] or "Voice"
        gender = v.get("gender") or "?"
        descriptive = v.get("descriptive") or "-"
        use_case = v.get("use_case") or "-"
        accent = entry.get("accent") or "-"
        print(
            f'    "{key}": "{v["voice_id"]}",'
            f'  # {gender}, {descriptive}, {use_case}, accent={accent}'
        )
    print("}")
    print()
    print("Next: pick ~9 of these, replace the existing VOICE_IDS above,")
    print("delete audio_variants/, then re-run --letter M to audition.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate German letter-phoneme + word audio via ElevenLabs.",
    )
    parser.add_argument(
        "--letter",
        metavar="L",
        help="Audition mode: generate only the 3 phoneme variants for this "
             "letter (e.g. --letter M) across every voice. Skips example "
             "words and tracing words — use this to pick a favourite voice "
             "cheaply before running the full inventory.",
    )
    parser.add_argument(
        "--list-voices",
        action="store_true",
        help="Discover mode: query ElevenLabs for voices verified for "
             "German on the current MODEL_ID. Prints a VOICE_IDS dict "
             "ready to paste. Use this when API output still sounds "
             "English-accented — the current VOICE_IDS likely point to "
             "voices that aren't actually verified for German.",
    )
    parser.add_argument(
        "--words-only",
        action="store_true",
        help="Words audition mode: generate only the tracing words "
             "(OMA, MAMA, AFFE, …) across every voice. Skips letter "
             "phonemes and example words. Whole German words give the "
             "model enough phonetic context that the voice's actual "
             "accent is unambiguous — use this when you want to verify "
             "a voice sounds German before committing to phoneme "
             "generation.",
    )
    args = parser.parse_args()

    if not API_KEY:
        sys.stderr.write("Set ELEVENLABS_API_KEY env var\n")
        return 1

    if args.list_voices:
        return list_german_voices()

    if args.letter and args.words_only:
        sys.stderr.write("--letter and --words-only are mutually exclusive.\n")
        return 1

    letters_to_run: dict[str, str] = LETTER_PHONEMES
    audition_letter = False
    audition_words = args.words_only
    if args.letter:
        key = args.letter.upper()
        if key not in LETTER_PHONEMES:
            sys.stderr.write(
                f"Unknown letter '{args.letter}'. Valid: "
                f"{''.join(LETTER_PHONEMES)}\n"
            )
            return 1
        letters_to_run = {key: LETTER_PHONEMES[key]}
        audition_letter = True
        print(f"Audition mode: only '{key}' phonemes across {len(VOICE_IDS)} voices.")
        print()
    elif audition_words:
        print(f"Words audition: {len(TRACING_WORDS)} words × {len(VOICE_IDS)} voices.")
        print()

    total_chars = 0
    for voice_name, voice_id in VOICE_IDS.items():
        print(f"=== {voice_name} ({voice_id}) ===")

        if not audition_words:
            # Letters: 3 variants of the phoneme + all example words.
            for letter, spoken in letters_to_run.items():
                folder = OUTPUT_ROOT / voice_name / letter
                for i, settings in enumerate(VARIANT_SETTINGS, start=1):
                    path = folder / f"{letter}{i}.mp3"
                    print(f"  {letter}{i}: '{spoken}' (stab={settings['stability']})")
                    total_chars += synthesise(spoken, voice_id, settings, path)
                    time.sleep(0.2)
                if audition_letter:
                    continue
                # One take of each example word — middle stability preset.
                for word in EXAMPLE_WORDS.get(letter, []):
                    path = folder / f"{word}.mp3"
                    print(f"      example: '{word}'")
                    total_chars += synthesise(word, voice_id, VARIANT_SETTINGS[1], path)
                    time.sleep(0.2)

        if audition_letter:
            continue

        # Tracing words: standalone audio for whole-word completion and
        # picker-level word pronunciation. Single take, middle settings.
        print(f"  -- tracing words --")
        words_folder = OUTPUT_ROOT / voice_name / "words"
        for word in TRACING_WORDS:
            path = words_folder / f"{word}.mp3"
            print(f"    '{word}'")
            total_chars += synthesise(word, voice_id, VARIANT_SETTINGS[1], path)
            time.sleep(0.2)

    print()
    print(f"Total characters billed: {total_chars}")
    if FAILED_REQUESTS:
        print(f"{len(FAILED_REQUESTS)} request(s) FAILED — do not copy this output into the app:",
              file=sys.stderr)
        for f in FAILED_REQUESTS:
            print(f"  ✗ {f}", file=sys.stderr)
        return 1
    print(f"Output: {OUTPUT_ROOT.absolute()}")
    print()
    if audition_letter:
        key = next(iter(letters_to_run))
        print("Audition next steps:")
        print(f"  1. Listen through audio_variants/*/{key}/{key}1.mp3 etc.")
        print("  2. Pick the voice that sounds most like a German")
        print("     Volksschule teacher to your ear.")
        print("  3. Re-run without --letter to generate the full inventory")
        print(f"     (takes ~2 min for all {len(VOICE_IDS)} voices).")
    elif audition_words:
        print("Words audition next steps:")
        print("  1. Listen through audio_variants/*/words/*.mp3")
        print("     — OMA, MAMA, AFFE are the clearest accent tests.")
        print("  2. If any voice sounds American reading German, it's not")
        print("     actually verified for German — run --list-voices.")
        print("  3. Once you've picked a voice, re-run without --words-only")
        print("     to generate the full inventory.")
    else:
        print("Next steps:")
        print("  1. cd audio_variants and listen through each voice folder.")
        print("  2. Pick a favourite voice (say 'Emilia').")
        print("  3. Copy each letter folder into the bundle, preserving names:")
        print("       for L in A B C D E ... ; do")
        print("         cp audio_variants/Emilia/$L/*.mp3 \\")
        print("            BuchstabenNative/Resources/Letters/$L/")
        print("       done")
        print("  4. Decide where tracing-word audio should live (new")
        print("     Resources/Words/ folder + a repo.loadWords() loader).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
