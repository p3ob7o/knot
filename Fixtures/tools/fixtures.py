"""Generates and checks Knot's synthetic fixtures.

Run it through Fixtures/tools/generate.sh. Fixtures/README.md says what each fixture is for.

Two kinds of output:

- Committed files: the reference transcript of the ten-minute clip, the ink fixtures and
  their previews, and Fixtures/manifest.json. They come from the repository's own texts
  and code only, so every Mac makes them byte for byte.
- Local audio, in Fixtures/generated/, which git ignores. It is spoken by the voices that
  ship with macOS, whose licence does not allow redistributing what they make, so it is
  never committed. Each Mac makes its own, and Fixtures/generated/manifest.json records the
  macOS build and the voices that made it, because another build gives other audio.

No step reads a microphone, the network or the owner's recordings.
"""

import argparse
import array
import hashlib
import json
import math
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import wave

GENERATOR_VERSION = 2
GENERATED = "generated"  # under Fixtures/, ignored by git
FIXTURES = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(FIXTURES)

SAMPLE_RATE = 16000
SPEECH_RATE = 175  # words per minute, pinned so that a user's speaking-rate setting cannot leak in

# Voices of the Eloquence family, which ship inside macOS
# (TextToSpeechKonaSupport.framework). They need no download.
VOICES = {
    "reed": ("Reed (English (US))", "en_US"),
    "shelley": ("Shelley (English (US))", "en_US"),
    "sandy": ("Sandy (English (US))", "en_US"),
    "eddy": ("Eddy (English (US))", "en_US"),
    "flo": ("Flo (English (US))", "en_US"),
    "reed-uk": ("Reed (English (UK))", "en_GB"),
}
VOICE_SOURCE = "Built into macOS: /System/Library/PrivateFrameworks/TextToSpeechKonaSupport.framework"

# One entry per audio fixture. The text of `audio/<name>.txt` is both what `say` speaks and the
# reference transcript. For `long` the generator writes `audio/long.txt` from the paragraphs of
# `audio/long.source.txt`. The expected lengths were measured on macOS 27.3 (26C5047e); a voice
# that speaks outside the tolerance on another build fails --check, so that the change is seen.
AUDIO = [
    {"name": "clean", "expectedSeconds": 17.5, "toleranceSeconds": 6, "voice": "reed", "kind": "speech",
     "about": "Clean speech: four plain sentences."},
    {"name": "fillers", "expectedSeconds": 17.9, "toleranceSeconds": 6, "voice": "shelley", "kind": "speech",
     "about": "Scripted fillers (um, uh, I mean), a repeated word and two spoken self-corrections."},
    {"name": "list", "expectedSeconds": 6.6, "toleranceSeconds": 3, "voice": "sandy", "kind": "speech",
     "about": "A spoken shopping list."},
    {"name": "numbers-names", "expectedSeconds": 18.3, "toleranceSeconds": 6, "voice": "eddy", "kind": "speech",
     "about": "Times, a date, an amount, a flight number, a room number and four names."},
    {"name": "short", "expectedSeconds": 1.4, "toleranceSeconds": 0.6, "voice": "sandy", "kind": "speech",
     "about": "A clip under two seconds, for the soak test and the discard rule."},
    {"name": "canary", "expectedSeconds": 6.7, "toleranceSeconds": 3, "voice": "shelley", "kind": "speech",
     "about": "Holds the made-up canary word of the end-to-end suite (Quillfarrow)."},
    {"name": "noisy", "expectedSeconds": 11.3, "toleranceSeconds": 4, "voice": "flo", "kind": "noisy",
     "about": "Clean speech mixed with seeded low-passed noise at 10 dB SNR."},
    {"name": "silence", "kind": "silence", "seconds": 10, "expectedSeconds": 10.0, "toleranceSeconds": 0,
     "about": "Ten seconds of a noise floor near -60 dBFS and no speech. The reference is empty."},
    {"name": "long", "voices": ["reed", "shelley", "reed-uk"], "kind": "long", "seconds": 600,
     "expectedSeconds": 600.0, "toleranceSeconds": 0,
     "about": "Exactly ten minutes of paragraphs in three voices with pauses, stored as AAC."},
]

NOISE_SEED = 0x4B4E4F54  # "KNOT"
FLOOR_AMPLITUDE = 56  # uniform in [-56, 56]: an RMS near 32, about -60 dBFS
NOISY_SNR_DB = 10
PAUSE_SECONDS = 1.2
LONG_BITRATE = 32000


class XorShift32:
    """A tiny seeded generator, so that noise and jitter never depend on Python's own."""

    def __init__(self, seed):
        self.state = (seed & 0xFFFFFFFF) or 1

    def next(self):
        x = self.state
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        self.state = x
        return x

    def signed(self, amplitude):
        """An integer in [-amplitude, amplitude]."""
        return self.next() % (2 * amplitude + 1) - amplitude

    def unit(self):
        """A float in [-1, 1], from integers only."""
        return (self.next() % 20001 - 10000) / 10000.0


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def run(command):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        sys.stderr.write(result.stderr.decode("utf-8", "replace"))
        raise SystemExit("fixtures: command failed: %s" % " ".join(command))
    return result.stdout.decode("utf-8", "replace")


def macos_build():
    return {
        "macOS": run(["/usr/bin/sw_vers", "-productVersion"]).strip(),
        "build": run(["/usr/bin/sw_vers", "-buildVersion"]).strip(),
        "arch": platform.machine(),
    }


# ---------------------------------------------------------------- audio


def write_wav(path, samples):
    """Writes 16-bit mono LPCM with a plain 44-byte header and no other chunks."""
    with wave.open(path, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(SAMPLE_RATE)
        out.writeframes(samples.tobytes() if sys.byteorder == "little" else _swapped(samples))


def _swapped(samples):
    copy = array.array("h", samples)
    copy.byteswap()
    return copy.tobytes()


def read_wav(path):
    with wave.open(path, "rb") as source:
        if source.getnchannels() != 1 or source.getsampwidth() != 2 or source.getframerate() != SAMPLE_RATE:
            raise SystemExit("fixtures: %s is not 16 kHz mono 16-bit" % path)
        samples = array.array("h")
        samples.frombytes(source.readframes(source.getnframes()))
        if sys.byteorder != "little":
            samples.byteswap()
        return samples


def check_voices():
    available = run(["/usr/bin/say", "-v", "?"])
    names = set()
    for line in available.splitlines():
        match = re.match(r"^(.*?)\s+[a-z]{2}_[A-Z]{2}\s+#", line)
        if match:
            names.add(match.group(1).strip())
    missing = [voice for voice, _ in VOICES.values() if voice not in names]
    if missing:
        raise SystemExit("fixtures: these built-in voices are missing: %s" % ", ".join(missing))


def speak(text, voice_key, work):
    voice = VOICES[voice_key][0]
    text_path = os.path.join(work, "say-input.txt")
    wav_path = os.path.join(work, "say-output.wav")
    with open(text_path, "w", encoding="utf-8") as handle:
        handle.write(text)
    run(["/usr/bin/say", "-v", voice, "-r", str(SPEECH_RATE), "--file-format=WAVE",
         "--data-format=LEI16@%d" % SAMPLE_RATE, "-o", wav_path, "-f", text_path])
    return read_wav(wav_path)


def floor_noise(count, rng):
    return array.array("h", (rng.signed(FLOOR_AMPLITUDE) for _ in range(count)))


def mix_floor(samples, rng):
    """Adds the noise floor, so that no fixture holds digital silence."""
    out = array.array("h", samples)
    for i in range(len(out)):
        out[i] = clamp(out[i] + rng.signed(FLOOR_AMPLITUDE))
    return out


def clamp(value):
    return 32767 if value > 32767 else (-32768 if value < -32768 else value)


def mean_square(samples):
    total = 0
    for value in samples:
        total += value * value
    return total // max(1, len(samples))


def make_noisy(speech, rng):
    """Mixes low-passed noise into the speech at NOISY_SNR_DB, in integers only."""
    raw = array.array("i", [0]) * len(speech)
    level = 0
    for i in range(len(speech)):
        white = rng.signed(16000)
        level += (white - level) >> 2  # a one-pole low-pass: noise like a room or traffic
        raw[i] = level
    voiced = array.array("h", (v for v in speech if abs(v) > 300))
    speech_power = mean_square(voiced)
    noise_power = mean_square(raw)
    ratio = 10 ** (NOISY_SNR_DB // 10)  # 10 dB is a power ratio of exactly 10
    scale_q12 = math.isqrt(speech_power * (1 << 24) // (ratio * max(1, noise_power)))
    out = array.array("h", speech)
    for i in range(len(out)):
        out[i] = clamp(out[i] + ((raw[i] * scale_q12) >> 12))
    measured = 10 * math.log10(speech_power / max(1, mean_square(array.array("i", ((n * scale_q12) >> 12 for n in raw)))))
    return out, round(measured, 1)


def zero_mp4_times(path):
    """Zeroes the creation and modification times that afconvert writes, so a rerun matches."""
    with open(path, "rb") as handle:
        data = bytearray(handle.read())

    def walk(start, end):
        i = start
        while i + 8 <= end:
            size = int.from_bytes(data[i:i + 4], "big")
            kind = bytes(data[i + 4:i + 8])
            header = 8
            if size == 1:
                size = int.from_bytes(data[i + 8:i + 16], "big")
                header = 16
            elif size == 0:
                size = end - i
            if size < header:
                raise SystemExit("fixtures: malformed MP4 box in %s" % path)
            if kind in (b"moov", b"trak", b"mdia"):
                walk(i + header, i + size)
            elif kind in (b"mvhd", b"tkhd", b"mdhd"):
                version = data[i + header]
                width = 8 if version == 1 else 4
                field = i + header + 4
                data[field:field + 2 * width] = bytes(2 * width)
            i += size

    walk(0, len(data))
    with open(path, "wb") as handle:
        handle.write(data)


def encode_aac(wav_path, m4a_path):
    run(["/usr/bin/afconvert", "-f", "m4af", "-d", "aac", "-b", str(LONG_BITRATE), wav_path, m4a_path])
    zero_mp4_times(m4a_path)


def read_text(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def write_text(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def long_paragraphs():
    text = read_text(os.path.join(FIXTURES, "audio", "long.source.txt"))
    return [p.strip().replace("\n", " ") for p in text.split("\n\n") if p.strip()]


def long_reference():
    return "\n\n".join(long_paragraphs()) + "\n"


def audio_path(spec):
    extension = "m4a" if spec["kind"] == "long" else "wav"
    return "%s/audio/%s.%s" % (GENERATED, spec["name"], extension)


def audio_format(spec):
    if spec["kind"] == "long":
        return {"container": "m4a", "codec": "aac", "bitRate": LONG_BITRATE,
                "sampleRate": SAMPLE_RATE, "channels": 1}
    return {"container": "wav", "codec": "lpcm", "bitsPerSample": 16,
            "sampleRate": SAMPLE_RATE, "channels": 1}


def describe_audio(out):
    """The committed description of each clip: its text, voice, format and expected length.

    It holds no checksum of the audio, because each Mac makes its own audio."""
    entries = []
    for index, spec in enumerate(AUDIO):
        name = spec["name"]
        if spec["kind"] == "long":
            reference = os.path.join(out, "audio", name + ".txt")
        else:
            reference = os.path.join(FIXTURES, "audio", name + ".txt")
        entry = {"name": name, "about": spec["about"], "file": audio_path(spec),
                 "reference": "audio/%s.txt" % name, "referenceSha256": sha256_of(reference),
                 "kind": spec["kind"], "format": audio_format(spec),
                 "expectedSeconds": spec["expectedSeconds"], "toleranceSeconds": spec["toleranceSeconds"],
                 "noiseSeed": NOISE_SEED + index}
        if "voice" in spec:
            entry["voice"] = VOICES[spec["voice"]][0]
        if "voices" in spec:
            entry["voices"] = [VOICES[key][0] for key in spec["voices"]]
        if spec["kind"] == "noisy":
            entry["snrDb"] = NOISY_SNR_DB
        if spec["kind"] == "long":
            entry["paragraphs"] = len(long_paragraphs())
            entry["pauseSeconds"] = PAUSE_SECONDS
        entries.append(entry)
    return entries


def build_audio(out, work, quiet=False):
    """Speaks every clip into <out>/generated/audio and writes <out>/generated/manifest.json."""
    check_voices()
    target = os.path.join(out, GENERATED, "audio")
    os.makedirs(target, exist_ok=True)
    entries = []
    for index, spec in enumerate(AUDIO):
        name = spec["name"]
        rng = XorShift32(NOISE_SEED + index)
        if spec["kind"] in ("speech", "noisy"):
            text = read_text(os.path.join(FIXTURES, "audio", name + ".txt")).strip()
            samples = speak(text, spec["voice"], work)
            if spec["kind"] == "noisy":
                samples, _ = make_noisy(samples, rng)
            else:
                samples = mix_floor(samples, rng)
        elif spec["kind"] == "silence":
            samples = floor_noise(spec["seconds"] * SAMPLE_RATE, rng)
        else:
            samples = build_long(spec, work, rng)
        file_path = os.path.join(out, audio_path(spec))
        if spec["kind"] == "long":
            wav_path = os.path.join(work, name + ".wav")
            write_wav(wav_path, samples)
            encode_aac(wav_path, file_path)
        else:
            write_wav(file_path, samples)
        seconds = round(len(samples) / SAMPLE_RATE, 3)
        entries.append({"name": name, "file": audio_path(spec), "frames": len(samples),
                        "durationSeconds": seconds, "sha256": sha256_of(file_path)})
        if not quiet:
            print("fixtures: %s %.1f s" % (audio_path(spec), seconds))
    local = {
        "schema": 1,
        "about": "Made on this Mac by Fixtures/tools/generate.sh. Never committed.",
        "generatorVersion": GENERATOR_VERSION,
        "madeOn": macos_build(),
        "speechRate": SPEECH_RATE,
        "voices": sorted(name for name, _ in VOICES.values()),
        "audio": entries,
    }
    write_text(os.path.join(out, GENERATED, "manifest.json"), json.dumps(local, indent=2) + "\n")
    return local


def build_long(spec, work, rng):
    """Every paragraph in turn, cycling voices, each followed by a pause, padded to the exact length."""
    total = spec["seconds"] * SAMPLE_RATE
    pause = int(PAUSE_SECONDS * SAMPLE_RATE)
    out = array.array("h")
    for index, paragraph in enumerate(long_paragraphs()):
        out.extend(speak(paragraph, spec["voices"][index % len(spec["voices"])], work))
        out.extend(array.array("h", [0]) * pause)
    if len(out) > total:
        raise SystemExit("fixtures: the paragraphs of long.source.txt take %.0f s with this Mac's voices, "
                         "more than %d s. Shorten the source." % (len(out) / SAMPLE_RATE, spec["seconds"]))
    out.extend(array.array("h", [0]) * (total - len(out)))
    return mix_floor(out, rng)


# ---------------------------------------------------------------- ink

K = 0.5523  # control distance for a quarter circle drawn with one cubic


def ellipse(cx, cy, rx, ry):
    """Starts at the top and runs anticlockwise, as most people draw an o."""
    return [
        ("M", cx, cy + ry),
        ("C", cx - K * rx, cy + ry, cx - rx, cy + K * ry, cx - rx, cy),
        ("C", cx - rx, cy - K * ry, cx - K * rx, cy - ry, cx, cy - ry),
        ("C", cx + K * rx, cy - ry, cx + rx, cy - K * ry, cx + rx, cy),
        ("C", cx + rx, cy + K * ry, cx + K * rx, cy + ry, cx, cy + ry),
    ]


def L(x, y):
    return ("L", x, y)


def M(x, y):
    return ("M", x, y)


def C(*values):
    return ("C",) + values


# A small single-line print alphabet. Units: the x-height is 1, the baseline is 0, y points up.
# Each glyph is (advance, [stroke, ...]); a stroke is one touch of the pen.
GLYPHS = {
    "a": (1.15, [ellipse(0.45, 0.5, 0.4, 0.5), [M(0.85, 1.0), L(0.85, 0.08), L(0.95, 0.0)]]),
    "b": (1.1, [[M(0.1, 2.0), L(0.1, 0.0), L(0.1, 0.6), C(0.25, 0.95, 0.85, 1.05, 0.9, 0.5),
                 C(0.95, 0.0, 0.35, -0.1, 0.1, 0.15)]]),
    "c": (0.95, [[M(0.85, 0.8), C(0.7, 1.05, 0.1, 1.05, 0.08, 0.5), C(0.06, -0.05, 0.7, -0.05, 0.85, 0.2)]]),
    "d": (1.15, [ellipse(0.45, 0.5, 0.4, 0.5), [M(0.85, 2.0), L(0.85, 0.0)]]),
    "e": (1.0, [[M(0.1, 0.5), L(0.85, 0.5), C(0.88, 0.95, 0.3, 1.1, 0.12, 0.65),
                 C(-0.02, 0.2, 0.4, -0.1, 0.85, 0.15)]]),
    "g": (1.15, [ellipse(0.45, 0.5, 0.4, 0.5), [M(0.85, 1.0), L(0.85, -0.4),
                                                 C(0.85, -0.85, 0.25, -0.9, 0.12, -0.55)]]),
    "h": (1.1, [[M(0.1, 2.0), L(0.1, 0.0), L(0.1, 0.55), C(0.2, 0.95, 0.85, 1.1, 0.85, 0.55), L(0.85, 0.0)]]),
    "i": (0.45, [[M(0.2, 1.0), L(0.2, 0.0)], [M(0.2, 1.45), L(0.23, 1.5)]]),
    "k": (1.0, [[M(0.1, 2.0), L(0.1, 0.0)], [M(0.8, 1.0), L(0.12, 0.45), L(0.85, 0.0)]]),
    "l": (0.45, [[M(0.2, 2.0), L(0.2, 0.15), C(0.2, 0.0, 0.3, -0.02, 0.4, 0.05)]]),
    "m": (1.6, [[M(0.1, 1.0), L(0.1, 0.0), L(0.1, 0.6), C(0.2, 1.0, 0.75, 1.05, 0.75, 0.55), L(0.75, 0.0),
                 L(0.75, 0.6), C(0.85, 1.0, 1.45, 1.05, 1.45, 0.55), L(1.45, 0.0)]]),
    "n": (1.1, [[M(0.1, 1.0), L(0.1, 0.0), L(0.1, 0.6), C(0.2, 1.0, 0.85, 1.05, 0.85, 0.55), L(0.85, 0.0)]]),
    "o": (1.05, [ellipse(0.5, 0.5, 0.42, 0.5)]),
    "r": (0.8, [[M(0.1, 1.0), L(0.1, 0.0), L(0.1, 0.55), C(0.2, 0.95, 0.55, 1.05, 0.75, 0.9)]]),
    "s": (0.9, [[M(0.78, 0.85), C(0.6, 1.05, 0.1, 1.0, 0.12, 0.72), C(0.14, 0.45, 0.78, 0.55, 0.78, 0.25),
                 C(0.78, -0.05, 0.2, -0.05, 0.08, 0.15)]]),
    "t": (0.75, [[M(0.3, 1.7), L(0.3, 0.15), C(0.3, -0.02, 0.5, -0.02, 0.65, 0.08)], [M(0.05, 1.0), L(0.62, 1.0)]]),
    "v": (1.0, [[M(0.05, 1.0), L(0.5, 0.0), L(0.95, 1.0)]]),
    "-": (0.8, [[M(0.1, 0.5), L(0.65, 0.5)]]),
}
SPACE = 0.6
TRACKING = 0.12
X_HEIGHT = 18.0  # points
SLANT = 0.18
PEN_WIDTH = 3.0
PEN_SPEED = 120.0  # points a second
GAP_STROKE = 0.12
GAP_GLYPH = 0.18
GAP_WORD = 0.35
GAP_LINE = 0.8
AZIMUTH = 0.785
ALTITUDE = 1.05
POINT_FIELDS = ["x", "y", "t", "size", "opacity", "force", "azimuth", "altitude"]

INK = [
    {"name": "line", "lines": ["call the vet at noon"], "canvas": (420, 120), "origin": (30, 70),
     "expectedText": "call the vet at noon",
     "about": "One line of print handwriting."},
    {"name": "list", "lines": ["- milk", "- eggs", "- bread"], "canvas": (260, 220), "origin": (30, 60),
     "expectedText": "- milk\n- eggs\n- bread",
     "about": "A list of three items, one a line, each with a dash."},
    {"name": "sketch", "canvas": (400, 300), "expectedText": "",
     "about": "A house, a sun and an arrow. It holds no words, so recognition should return no text."},
]


def jitter_path(path, rng, amount):
    out = []
    for segment in path:
        values = [v + rng.unit() * amount for v in segment[1:]]
        out.append((segment[0],) + tuple(values))
    return out


def transform(path, scale, dx, dy, slant, flip):
    out = []
    for segment in path:
        values = list(segment[1:])
        coords = []
        for j in range(0, len(values), 2):
            x, y = values[j], values[j + 1]
            x = x + slant * y
            coords.extend([dx + x * scale, dy - y * scale if flip else dy + y * scale])
        out.append((segment[0],) + tuple(coords))
    return out


def handwriting(spec, rng):
    strokes = []
    x0, baseline = spec["origin"]
    line_height = X_HEIGHT * 3.0
    for line_index, text in enumerate(spec["lines"]):
        pen = 0.0
        for char_index, char in enumerate(text):
            gap = GAP_LINE if char_index == 0 and line_index > 0 else GAP_GLYPH
            if char == " ":
                pen += SPACE
                gap = GAP_WORD
                continue
            advance, glyph = GLYPHS[char]
            offset_x = rng.unit() * 0.04
            offset_y = rng.unit() * 0.04
            for stroke_index, path in enumerate(glyph):
                shaky = jitter_path(path, rng, 0.025)
                placed = transform(shaky, X_HEIGHT, x0 + (pen + offset_x) * X_HEIGHT,
                                   baseline + line_index * line_height - offset_y * X_HEIGHT, SLANT, True)
                strokes.append({"gapBefore": gap if stroke_index == 0 else GAP_STROKE, "path": placed})
            pen += advance + TRACKING
    return strokes


def sketch(rng):
    shapes = [
        [M(120, 260), L(120, 160), L(240, 160), L(240, 260), L(120, 260)],  # walls
        [M(108, 168), L(180, 98), L(252, 168)],  # roof
        [M(165, 260), L(165, 212), L(195, 212), L(195, 260)],  # door
        [M(135, 180), L(155, 180), L(155, 200), L(135, 200), L(135, 180)],  # window
        ellipse(330, 80, 26, 26),  # sun
    ]
    for ray in range(8):
        angle = ray * math.pi / 4
        c, s = round(math.cos(angle), 6), round(math.sin(angle), 6)
        shapes.append([M(330 + 34 * c, 80 + 34 * s), L(330 + 48 * c, 80 + 48 * s)])
    shapes.append([M(340, 250), C(320, 262, 290, 250, 262, 226)])  # arrow shaft
    shapes.append([M(268, 244), L(262, 226), L(281, 228)])  # arrow head
    strokes = []
    for index, path in enumerate(shapes):
        strokes.append({"gapBefore": 0.0 if index == 0 else 0.3, "path": jitter_path(path, rng, 1.2)})
    return strokes


def bezier_point(p0, segment, t):
    if segment[0] == "L":
        return (p0[0] + (segment[1] - p0[0]) * t, p0[1] + (segment[2] - p0[1]) * t)
    _, x1, y1, x2, y2, x3, y3 = segment
    u = 1.0 - t
    a, b, c, d = u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t
    return (a * p0[0] + b * x1 + c * x2 + d * x3, a * p0[1] + b * y1 + c * y2 + d * y3)


def segment_length(p0, segment):
    total = 0.0
    previous = p0
    for step in range(1, 33):
        point = bezier_point(p0, segment, step / 32.0)
        total += math.sqrt((point[0] - previous[0]) ** 2 + (point[1] - previous[1]) ** 2)
        previous = point
    return total


def sample_stroke(path, start_time):
    """Points about every two points along the path, timed at PEN_SPEED, with a force ramp."""
    points = []
    current = (path[0][1], path[0][2])
    points.append((current, 0.0))
    distance = 0.0
    for segment in path[1:]:
        length = segment_length(current, segment)
        steps = max(2, int(math.ceil(length / 2.0)))
        for step in range(1, steps + 1):
            point = bezier_point(current, segment, step / float(steps))
            distance += length / steps
            points.append((point, distance))
        current = (segment[-2], segment[-1])
    total = max(distance, 1e-9)
    out = []
    for (x, y), travelled in points:
        progress = travelled / total
        if progress < 0.15:
            force = 0.3 + progress / 0.15 * 0.4
        elif progress > 0.85:
            force = 0.7 - (progress - 0.85) / 0.15 * 0.3
        else:
            force = 0.7
        out.append([round(x, 2), round(y, 2), round(start_time + travelled / PEN_SPEED, 4),
                    PEN_WIDTH, 1.0, round(force, 3), AZIMUTH, ALTITUDE])
    return out, start_time + total / PEN_SPEED


def svg_path(path):
    parts = []
    for segment in path:
        parts.append(segment[0] + " " + " ".join("%.2f" % v for v in segment[1:]))
    return " ".join(parts)


def build_ink(out):
    target = os.path.join(out, "ink")
    os.makedirs(target, exist_ok=True)
    entries = []
    for index, spec in enumerate(INK):
        rng = XorShift32(NOISE_SEED + 100 + index)
        strokes = handwriting(spec, rng) if "lines" in spec else sketch(rng)
        clock = 0.0
        stroke_records = []
        point_count = 0
        for stroke in strokes:
            clock += stroke["gapBefore"]
            points, clock = sample_stroke(stroke["path"], clock)
            point_count += len(points)
            stroke_records.append({
                "path": [[s[0]] + [round(v, 2) for v in s[1:]] for s in stroke["path"]],
                "points": points,
            })
        width, height = spec["canvas"]
        document = {
            "schema": 1,
            "name": spec["name"],
            "about": spec["about"],
            "expectedText": spec["expectedText"],
            "canvas": {"width": width, "height": height, "unit": "pt", "origin": "top-left, y down"},
            "ink": {"type": "pen", "color": "#000000", "width": PEN_WIDTH},
            "pointFields": POINT_FIELDS,
            "strokes": stroke_records,
        }
        json_path = os.path.join(target, spec["name"] + ".json")
        write_text(json_path, json.dumps(document, indent=1, sort_keys=False) + "\n")
        svg = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">'
               % (width, height, width, height),
               '<rect width="100%" height="100%" fill="#ffffff"/>']
        for record in stroke_records:
            svg.append('<path d="%s" fill="none" stroke="#000000" stroke-width="%.1f" '
                       'stroke-linecap="round" stroke-linejoin="round"/>'
                       % (svg_path([tuple(s) for s in record["path"]]), PEN_WIDTH))
        svg.append("</svg>")
        svg_path_name = os.path.join(target, spec["name"] + ".svg")
        write_text(svg_path_name, "\n".join(svg) + "\n")
        entries.append({
            "name": spec["name"], "about": spec["about"], "file": "ink/%s.json" % spec["name"],
            "preview": "ink/%s.svg" % spec["name"], "expectedText": spec["expectedText"],
            "strokes": len(stroke_records), "points": point_count,
            "durationSeconds": round(clock, 3),
            "sha256": sha256_of(json_path), "previewSha256": sha256_of(svg_path_name),
        })
        print("fixtures: ink/%s.json %d strokes" % (spec["name"], len(stroke_records)))
    return entries


# ---------------------------------------------------------------- generate


def generate_committed(out, quiet=False):
    """Writes the files that are committed. They depend on nothing but the repository."""
    os.makedirs(os.path.join(out, "audio"), exist_ok=True)
    write_text(os.path.join(out, "audio", "long.txt"), long_reference())
    saved = sys.stdout
    if quiet:
        sys.stdout = open(os.devnull, "w")
    try:
        ink = build_ink(out)
    finally:
        if quiet:
            sys.stdout.close()
            sys.stdout = saved
    manifest = {
        "schema": 2,
        "generator": "Fixtures/tools/fixtures.py",
        "generatorVersion": GENERATOR_VERSION,
        "speechRate": SPEECH_RATE,
        "voices": [{"key": key, "name": name, "locale": locale, "source": VOICE_SOURCE}
                   for key, (name, locale) in sorted(VOICES.items())],
        "generatedAudio": GENERATED + "/manifest.json",
        "audio": describe_audio(out),
        "ink": ink,
    }
    write_text(os.path.join(out, "manifest.json"), json.dumps(manifest, indent=2) + "\n")
    if not quiet:
        print("fixtures: wrote %s" % os.path.join(out, "manifest.json"))
    return manifest


def generate_audio(out, quiet=False):
    work = tempfile.mkdtemp(prefix="knot-fixtures-")
    try:
        local = build_audio(out, work, quiet)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if not quiet:
        print("fixtures: wrote %s" % os.path.join(out, GENERATED, "manifest.json"))
    return local


# ---------------------------------------------------------------- checks


class Report:
    def __init__(self):
        self.failures = []
        self.notes = []

    def fail(self, message):
        self.failures.append(message)

    def note(self, message):
        self.notes.append(message)


def check_committed(report):
    """Committed files match the committed manifest, and a fresh run makes them byte for byte."""
    committed_path = os.path.join(FIXTURES, "manifest.json")
    if not os.path.exists(committed_path):
        report.fail("fixture_missing: Fixtures/manifest.json. Run Fixtures/tools/generate.sh --committed.")
        return
    committed = json.loads(read_text(committed_path))
    before = len(report.failures)
    checks = [(entry["reference"], entry.get("referenceSha256")) for entry in committed["audio"]]
    for entry in committed["ink"]:
        checks += [(entry["file"], entry.get("sha256")), (entry["preview"], entry.get("previewSha256"))]
    for relative, digest in checks:
        path = os.path.join(FIXTURES, relative)
        if not os.path.exists(path):
            report.fail("fixture_missing: Fixtures/%s" % relative)
        elif sha256_of(path) != digest:
            report.fail("fixture_changed: Fixtures/%s differs from Fixtures/manifest.json" % relative)
    out = tempfile.mkdtemp(prefix="knot-fixtures-check-")
    try:
        try:
            fresh = generate_committed(out, quiet=True)
        except (IOError, OSError) as error:
            missing_input(report, error)
            return
        paths = ["manifest.json", "audio/long.txt"]
        for entry in fresh["ink"]:
            paths += [entry["file"], entry["preview"]]
        for relative in paths:
            compare_one(report, out, relative)
    finally:
        shutil.rmtree(out, ignore_errors=True)
    if len(report.failures) == before:
        report.note("committed files: %d regenerated byte for byte (%s), and %d match their checksums in the manifest"
                    % (len(paths), ", ".join(paths), len(checks)))


def missing_input(report, error):
    """Reports a committed input that a regeneration could not read, once, as fixture_missing."""
    path = getattr(error, "filename", None) or str(error)
    path = os.path.abspath(path)
    if path.startswith(REPO + os.sep):
        message = "fixture_missing: %s" % os.path.relpath(path, REPO)
    else:
        message = "fixture_missing: %s (%s)" % (path, error.strerror or error)
    if message not in report.failures:
        report.fail(message)


def check_audio(report):
    """Speaks every clip into a temporary folder and checks its format and length.

    Encoded audio is not compared byte for byte: each Mac makes its own."""
    out = tempfile.mkdtemp(prefix="knot-fixtures-audio-")
    before = len(report.failures)
    try:
        try:
            local = generate_audio(out, quiet=True)
        except (IOError, OSError) as error:
            missing_input(report, error)
            return
        by_name = dict((spec["name"], spec) for spec in AUDIO)
        for entry in local["audio"]:
            spec = by_name[entry["name"]]
            path = os.path.join(out, entry["file"])
            if not os.path.exists(path) or os.path.getsize(path) == 0:
                report.fail("audio: %s was not made" % entry["file"])
                continue
            if abs(entry["durationSeconds"] - spec["expectedSeconds"]) > spec["toleranceSeconds"]:
                report.fail("audio: %s lasts %.1f s, expected %.1f s within %.1f s; the voices on this Mac "
                            "may have changed" % (entry["file"], entry["durationSeconds"],
                                                  spec["expectedSeconds"], spec["toleranceSeconds"]))
            if spec["kind"] != "long":
                clip = wave.open(path, "rb")
                try:
                    shape = (clip.getnchannels(), clip.getsampwidth(), clip.getframerate())
                finally:
                    clip.close()
                if shape != (1, 2, SAMPLE_RATE):
                    report.fail("audio: %s is not 16 kHz mono 16-bit" % entry["file"])
        if len(report.failures) == before:
            report.note("audio: %d clips spoken on macOS %s (%s), each of the expected format and length; "
                        "encoded audio is not compared byte for byte"
                        % (len(local["audio"]), local["madeOn"]["macOS"], local["madeOn"]["build"]))
    finally:
        shutil.rmtree(out, ignore_errors=True)
    present = os.path.join(FIXTURES, GENERATED, "manifest.json")
    if os.path.exists(present):
        made = json.loads(read_text(present))["madeOn"]
        report.note("local audio present in Fixtures/%s/, made on macOS %s (%s)"
                    % (GENERATED, made["macOS"], made["build"]))
    else:
        report.note("no local audio yet: tests that need it fail with fixture_missing until "
                    "Fixtures/tools/generate.sh --audio has run")


def compare_one(report, fresh_root, relative):
    """Fails when a committed file is absent or differs from the same file made by a fresh run."""
    committed = os.path.join(FIXTURES, relative)
    if not os.path.exists(committed):
        report.fail("fixture_missing: Fixtures/%s" % relative)
    elif read_bytes(os.path.join(fresh_root, relative)) != read_bytes(committed):
        report.fail("not_reproducible: Fixtures/%s does not match a fresh run" % relative)


def read_bytes(path):
    with open(path, "rb") as handle:
        return handle.read()


WORD_EDGE = ".,;:!?\"()[]{}—–-*…"


def words(text):
    out = []
    for token in text.replace("\n", " ").replace("-", " ").split():
        token = token.strip(WORD_EDGE).lower().replace("’", "'")
        if token:
            out.append(token)
    return out


def removed_words(raw, cleaned):
    """The words of raw that cleaned leaves out, or None when cleaned is not a subsequence."""
    removed = []
    j = 0
    for word in raw:
        if j < len(cleaned) and cleaned[j] == word:
            j += 1
        else:
            removed.append(word)
    return removed if j == len(cleaned) else None


def contains_in_order(haystack, needles):
    position = 0
    for needle in needles:
        found = find_run(haystack, needle, position)
        if found < 0:
            return needle
        position = found + len(needle)
    return None


def find_run(haystack, needle, start):
    for i in range(start, len(haystack) - len(needle) + 1):
        if haystack[i:i + len(needle)] == needle:
            return i
    return -1


CLEANUP_CATEGORIES = {"negation", "amount", "date", "name", "self-correction", "punctuation",
                      "filler", "filler-lookalike", "repeat", "restart", "list", "paragraphs",
                      "question", "already-clean", "run-on", "casing", "single-filler"}
CRITICAL_NEEDS = ["negation", "amount", "date", "name", "self-correction", "punctuation"]


def check_cleanup(report):
    path = os.path.join(FIXTURES, "cleanup", "cases.json")
    if not os.path.exists(path):
        report.fail("fixture_missing: Fixtures/cleanup/cases.json")
        return
    data = json.loads(read_text(path))
    cases = data["cases"]
    if len(cases) != 30:
        report.fail("cleanup: expected 30 cases, found %d" % len(cases))
    critical = [c for c in cases if c["meaningCritical"]]
    if len(critical) < 10:
        report.fail("cleanup: expected at least 10 meaning-critical cases, found %d" % len(critical))
    for need in CRITICAL_NEEDS:
        if not any(need in c["categories"] for c in critical):
            report.fail("cleanup: no meaning-critical case of category %s" % need)
    seen = set()
    for case in cases:
        cid = case["id"]
        if cid in seen:
            report.fail("cleanup: duplicate id %s" % cid)
        seen.add(cid)
        unknown = set(case["categories"]) - CLEANUP_CATEGORIES
        if unknown:
            report.fail("cleanup %s: unknown categories %s" % (cid, sorted(unknown)))
        raw = words(case["raw"])
        reference = words(case["reference"])
        removed = removed_words(raw, reference)
        if removed is None:
            report.fail("cleanup %s: the reference adds, changes or reorders words of the raw text" % cid)
        elif sorted(removed) != sorted(w.lower() for w in case["remove"]):
            report.fail("cleanup %s: the reference removes %s, but the case lists %s"
                        % (cid, removed, case["remove"]))
        missing = contains_in_order(raw, [words(k) for k in case["keep"]])
        if missing:
            report.fail("cleanup %s: keep phrase %r is not in the raw text in order" % (cid, " ".join(missing)))
        missing = contains_in_order(reference, [words(k) for k in case["keep"]])
        if missing:
            report.fail("cleanup %s: keep phrase %r is not in the reference" % (cid, " ".join(missing)))
        for pattern in case.get("mustNotMatch", []):
            if re.search(pattern, case["reference"], re.IGNORECASE):
                report.fail("cleanup %s: the reference matches its own forbidden pattern %r" % (cid, pattern))
        for wrong in case.get("wrong", []):
            if "punctuation" in case["categories"]:
                if words(wrong["output"]) != reference:
                    report.fail("cleanup %s: a punctuation trap must keep every word of the reference" % cid)
                if not any(re.search(p, wrong["output"], re.IGNORECASE) for p in case.get("mustNotMatch", [])):
                    report.fail("cleanup %s: no forbidden pattern catches the wrong output %r"
                                % (cid, wrong["output"]))
        if "punctuation" in case["categories"] and not case.get("mustNotMatch"):
            report.fail("cleanup %s: a punctuation case needs mustNotMatch" % cid)
    report.note("cleanup: %d cases, %d meaning-critical" % (len(cases), len(critical)))


def normalise_space(text):
    return " ".join(text.split())


def check_read_aloud(report):
    folder = os.path.join(FIXTURES, "read-aloud")
    passages = {}
    for number in range(1, 11):
        path = os.path.join(folder, "%02d.txt" % number)
        if not os.path.exists(path):
            report.fail("fixture_missing: Fixtures/read-aloud/%02d.txt" % number)
            continue
        passages[number] = normalise_space(read_text(path))
    doc_path = os.path.join(REPO, "docs", "checklists", "G4-read-aloud.md")
    if not os.path.exists(doc_path):
        report.fail("checklists: docs/checklists/G4-read-aloud.md is missing")
        return
    doc = read_text(doc_path)
    for number, text in passages.items():
        match = re.search(r"^## Passage %d\n(.*?)(?=^## |\Z)" % number, doc, re.M | re.S)
        if not match:
            report.fail("read-aloud: passage %d is missing from the owner's script" % number)
            continue
        body = match.group(1)
        quoted = normalise_space(" ".join(line[1:].strip() for line in body.splitlines() if line.startswith(">")))
        if quoted != text:
            report.fail("read-aloud: passage %d in the owner's script differs from Fixtures/read-aloud/%02d.txt"
                        % (number, number))
        for device in ("iphone", "watch"):
            if "read-aloud-%02d-%s" % (number, device) not in body:
                report.fail("read-aloud: passage %d does not name read-aloud-%02d-%s" % (number, number, device))
    notes_path = os.path.join(REPO, "docs", "checklists", "G4-spontaneous-notes.md")
    if not os.path.exists(notes_path):
        report.fail("checklists: docs/checklists/G4-spontaneous-notes.md is missing")
    else:
        notes = read_text(notes_path)
        names = re.findall(r"note-(\d{2})-(iphone|watch)", notes)
        numbers = sorted(set(int(n) for n, _ in names))
        if numbers != list(range(1, 11)):
            report.fail("spontaneous notes: expected note-01 to note-10, found %s" % numbers)
    report.note("read-aloud: %d passages match the owner's script" % len(passages))


ROW = re.compile(r"^\|\s*(M\d\.\d-\d{2})\s*\|(.*)\|\s*$")
SITTING = re.compile(r"^## Sitting (\d)\b")


def check_checklists(report):
    folder = os.path.join(REPO, "docs", "checklists")
    ids = {}
    for milestone in range(1, 8):
        path = os.path.join(folder, "M%d.md" % milestone)
        if not os.path.exists(path):
            report.fail("checklists: docs/checklists/M%d.md is missing" % milestone)
            continue
        sitting = None
        counts = {}
        for number, line in enumerate(read_text(path).splitlines(), 1):
            heading = SITTING.match(line)
            if heading:
                sitting = int(heading.group(1))
                counts[sitting] = 0
                continue
            row = ROW.match(line)
            if not row:
                if re.match(r"^\|\s*M\d", line):
                    report.fail("checklists: M%d.md line %d looks like a row but does not parse" % (milestone, number))
                continue
            row_id = row.group(1)
            cells = [c.strip() for c in row.group(2).split("|")]
            where = "M%d.md line %d (%s)" % (milestone, number, row_id)
            if sitting is None:
                report.fail("checklists: %s sits outside a sitting" % where)
                continue
            counts[sitting] += 1
            expected_id = "M%d.%d-%02d" % (milestone, sitting, counts[sitting])
            if row_id != expected_id:
                report.fail("checklists: %s should be numbered %s" % (where, expected_id))
            if row_id in ids:
                report.fail("checklists: %s repeats an ID" % where)
            ids[row_id] = cells
            if len(cells) != 5:
                report.fail("checklists: %s needs the cells Device, Do, Expect, Result and Notes" % where)
                continue
            if not cells[0] or not cells[1] or not cells[2]:
                report.fail("checklists: %s has an empty Device, Do or Expect cell" % where)
            if cells[3] != "☐ pass ☐ fail":
                report.fail("checklists: %s needs the box '☐ pass ☐ fail'" % where)
        if not counts:
            report.fail("checklists: M%d.md has no sitting" % milestone)
        for sitting_number, count in counts.items():
            if count > 20:
                report.fail("checklists: M%d sitting %d has %d rows, more than 20" % (milestone, sitting_number, count))
            if count == 0:
                report.fail("checklists: M%d sitting %d has no rows" % (milestone, sitting_number))
    check_coverage(report, ids)
    report.note("checklists: %d rows in M1 to M7, no sitting above 20 rows" % len(ids))


def section_17_hardware_items():
    text = read_text(os.path.join(REPO, "docs", "architecture.md"))
    match = re.search(r"^\| Hardware \| (.*?) \|", text, re.M)
    if not match:
        return None
    return [item.strip() for item in match.group(1).split(",")]


def check_coverage(report, ids):
    readme = read_text(os.path.join(REPO, "docs", "checklists", "README.md"))
    block = re.search(r"<!-- coverage:begin -->(.*?)<!-- coverage:end -->", readme, re.S)
    if not block:
        report.fail("checklists: README.md has no coverage table")
        return
    covered = {}
    for line in block.group(1).splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 3 or cells[0] in ("Item", "---") or cells[0].startswith("-"):
            continue
        refs = re.findall(r"M\d\.\d-\d{2}", cells[2])
        if not refs:
            report.fail("checklists: coverage item %r names no row" % cells[0])
        for ref in refs:
            if ref not in ids:
                report.fail("checklists: coverage item %r names %s, which does not exist" % (cells[0], ref))
        covered[cells[0].lower()] = refs
    items = section_17_hardware_items()
    if items is None:
        report.fail("checklists: could not read the Hardware row of docs/architecture.md section 17")
        return
    for item in items:
        if item.lower() not in covered:
            report.fail("checklists: the section 17 hardware item %r has no coverage row" % item)
    report.note("checklists: section 17 hardware items covered: %s"
                % "; ".join("%s -> %s" % (i, ", ".join(covered.get(i.lower(), []))) for i in items))


OWNER_FILE = re.compile(r"^(read-aloud|note)-\d+-[a-z]+\.(m4a|wav|caf|txt|json)$")


def check_no_owner_files(report):
    """The owner's recordings live in KNOT_LOCAL_FIXTURES and never in the repository."""
    for folder, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d not in (".git", ".build", "DerivedData", "build")]
        for name in files:
            if OWNER_FILE.match(name):
                report.fail("privacy: %s looks like one of the owner's recordings or something made from one"
                            % os.path.relpath(os.path.join(folder, name), REPO))


def check(skip_audio):
    report = Report()
    steps = [check_committed] + ([] if skip_audio else [check_audio])
    steps += [check_cleanup, check_read_aloud, check_checklists, check_no_owner_files]
    for step in steps:
        try:
            step(report)
        except (IOError, OSError) as error:
            missing_input(report, error)  # a file the step needs is gone: report it, never a traceback
    for note in report.notes:
        print("fixtures: " + note)
    for failure in report.failures:
        print("fixtures: FAIL " + failure, file=sys.stderr)
    if report.failures:
        print("fixtures: check failed, %d problem(s)" % len(report.failures), file=sys.stderr)
        return 1
    print("fixtures: check passed")
    return 0


def main():
    parser = argparse.ArgumentParser(description="Generate and check Knot's synthetic fixtures.")
    parser.add_argument("--out", help="write under this folder instead of Fixtures/")
    parser.add_argument("--audio", action="store_true", help="only speak the local audio into generated/")
    parser.add_argument("--committed", action="store_true", help="only write the committed files")
    parser.add_argument("--check", action="store_true",
                        help="regenerate into temporary folders, compare the committed files and lint")
    parser.add_argument("--lint-only", action="store_true", help="with --check, skip speaking the audio")
    args = parser.parse_args()
    out = os.path.abspath(args.out) if args.out else FIXTURES
    local = os.environ.get("KNOT_LOCAL_FIXTURES")
    if local and (out + os.sep).startswith(os.path.abspath(local) + os.sep):
        raise SystemExit("fixtures: refusing to write into KNOT_LOCAL_FIXTURES")
    if args.check:
        return check(args.lint_only)
    if not args.audio:
        generate_committed(out)
    if not args.committed:
        generate_audio(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
