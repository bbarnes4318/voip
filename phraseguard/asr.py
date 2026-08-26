#!/usr/bin/env python3
"""Speech recognition for PhraseGuard: Vosk with a constrained grammar.

WHY A CONSTRAINED GRAMMAR AND NOT TRANSCRIPTION
----------------------------------------------
This is a keyword-spotting problem, not a transcription problem. Nothing
downstream ever needs to know what was said -- it needs to know whether one of
roughly two hundred phrases was said. Handing that to an open-vocabulary
recogniser buys nothing and costs an order of magnitude.

Vosk accepts a grammar as a JSON list of phrases at recogniser construction
time. With one, the decoder searches a lattice built from the corpus rather
than a general English language model: it is smaller, it is faster, and its
errors land inside the corpus vocabulary, which is where the fuzzy matcher is
already looking. The cost is that anything outside the grammar comes back as
"[unk]", which is exactly the trade we want -- the +/-10 word context in a log
record is context from the corpus vocabulary, not a transcript of a consumer's
private conversation. That is a privacy property, not just a performance one.

  MODEL REQUIREMENT: the grammar path needs a model built with one, i.e. one
  that ships Gr.fst. vosk-model-small-en-us-0.15 does. The large
  vosk-model-en-us-0.22 does NOT, and passing a grammar to it silently gets
  you open transcription at ten times the CPU. build_recognizer() checks and
  says so rather than letting that happen quietly.

WHY NOT CLOUD ASR
-----------------
Priced before being rejected, as the brief asks. Streaming recognisers are
billed per connected minute of audio, not per call, and the customer leg is
open for the whole call. At the ~62 concurrent channels this box peaks at,
with the customer-leg and RMS filters already applied, the surviving audio is
still on the order of tens of thousands of minutes a day. At the published
$0.02-$0.04 per streaming minute that is four to five figures a month, per
box, to run a detector that must fail open anyway -- and it puts the customer's
live call audio on a third-party wire, which is a materially worse position to
defend than "we decoded it in memory and discarded it". Self-hosted CPU Vosk
has a fixed cost, no per-minute meter, and no egress.

FAIL OPEN
---------
If Vosk is not installed, or the model is missing, or a recogniser throws,
this module returns a NullRecognizer and the daemon runs with detection
disabled. It logs loudly and it does not exit. A missing speech model must
never be the reason a call fails to connect.

  ./asr.py --bench          measure realtime factor and cores per stream
  ./asr.py --grammar        print the grammar this corpus produces
"""
import json
import os
import sys
import time

try:
    from .matcher import Corpus, _NUMBER_WORDS
except ImportError:                                    # run as a script
    from matcher import Corpus, _NUMBER_WORDS

SAMPLE_RATE = 8000

# Vosk's out-of-grammar token. normalize() in matcher.py strips it, but it is
# named here too so the daemon can count how much of what it hears is outside
# the corpus -- a useful shadow-mode number in its own right.
UNK = "[unk]"

_vosk = None
_vosk_error = None


def _import_vosk():
    global _vosk, _vosk_error
    if _vosk is not None or _vosk_error is not None:
        return _vosk
    try:
        import vosk                                    # noqa: PLC0415
        vosk.SetLogLevel(-1)
        _vosk = vosk
    except Exception as e:                             # noqa: BLE001
        _vosk_error = str(e)
    return _vosk


class NullRecognizer(object):
    """Accepts audio, recognises nothing, never raises.

    This is what the daemon runs on when Vosk is unavailable. It exists so
    that "no speech model on this box" is a degraded detector rather than a
    daemon that will not start -- and so that the tap, the SIP correlation and
    the per-customer counters keep working, because those are useful on their
    own.
    """
    available = False

    def __init__(self, reason=""):
        self.reason = reason
        self.audio_seconds = 0.0

    def accept(self, pcm):
        self.audio_seconds += len(pcm) / float(SAMPLE_RATE * 2)
        return None

    def final(self):
        return None

    def close(self):
        pass


def _confidence(result):
    """Mean per-word confidence from a Vosk result, or None.

    SetWords(True) gives a "result" array with a conf per word. The mean is
    what goes in the log record: it is the number a human reviewing a
    shadow-mode hit needs in order to tell "the recogniser was sure and the
    phrase is a false positive" from "the recogniser was guessing".

    Vosk omits the array when a grammar is in force on some model builds, so
    this returns None rather than inventing a number. A missing confidence is
    a fact about the recogniser; a fabricated 1.0 is a lie in an evidence log.
    """
    words = result.get("result")
    if not words:
        return None
    confs = [w.get("conf") for w in words if isinstance(w.get("conf"), (int, float))]
    if not confs:
        return None
    return round(sum(confs) / len(confs), 4)


class VoskRecognizer(object):
    """One Vosk recogniser bound to one RTP stream.

    Created when a stream's RMS gate opens and destroyed when the stream goes
    idle. Recognisers are per-stream because Vosk decoder state is per-stream;
    the MODEL behind them is shared and loaded exactly once per process.
    """
    available = True

    def __init__(self, model, grammar_json, sample_rate=SAMPLE_RATE):
        vosk = _import_vosk()
        if grammar_json:
            self.rec = vosk.KaldiRecognizer(model, sample_rate, grammar_json)
        else:
            self.rec = vosk.KaldiRecognizer(model, sample_rate)
        self.rec.SetWords(True)
        self.audio_seconds = 0.0
        self.decode_seconds = 0.0

    def accept(self, pcm):
        """Feed PCM16. Returns (text, confidence) or None if nothing finalised.

        Partials are deliberately ignored. A partial can be retracted by the
        next frame, and acting on retractable text is how a detector
        disconnects a call over a word that was never said.
        """
        self.audio_seconds += len(pcm) / float(SAMPLE_RATE * 2)
        t0 = time.time()
        try:
            done = self.rec.AcceptWaveform(pcm)
        finally:
            self.decode_seconds += time.time() - t0
        if not done:
            return None
        return self._parse(self.rec.Result)

    def final(self):
        return self._parse(self.rec.FinalResult)

    @staticmethod
    def _parse(getter):
        try:
            r = json.loads(getter())
        except Exception:                              # noqa: BLE001
            return None
        text = r.get("text")
        if not text:
            return None
        return (text, _confidence(r))

    def close(self):
        self.rec = None


def build_grammar(corpus):
    """A Vosk grammar JSON string from the corpus.

    The grammar is the set of WORDS the corpus can produce, plus [unk]. Vosk
    accepts a list of phrases and builds the lattice itself, but passing whole
    phrases makes the decoder prefer complete corpus phrases over the partial
    ones that heavily accented speech actually produces -- and partials are
    what the fuzzy matcher is built to work with. Words give the matcher the
    freedom to do its job.

    Tier C and Tier X vocabulary is included, and has to be: a suppressor or an
    exclusion that the recogniser cannot hear is a suppressor that never
    suppresses. Leaving them out is how a compliant insurance floor loses the
    disclaimer that protects it.
    """
    words = set()
    for p in corpus.phrases:
        for t in p.tokens:
            # Digits are what normalize() folds number words INTO, but the
            # acoustic model only knows the words. Both go in the grammar and
            # normalisation reunites them downstream.
            words.add(t)
            words.update(_WORDS_FOR_DIGIT.get(t, ()))
    words = sorted(w for w in words if w and not w.isdigit())
    return json.dumps(words + [UNK])


def _invert_number_words():
    """digit -> every spoken word that normalises to it.

    Built from matcher._NUMBER_WORDS rather than hand-copied. The copy that
    used to live here had already drifted: it omitted "oh", so a corpus phrase
    containing a zero would have had normalize() folding a spoken "oh" to "0"
    while the grammar had no "oh" for the decoder to emit. One list, inverted
    once at import, cannot drift.
    """
    out = {}
    for word, digit in _NUMBER_WORDS.items():
        out.setdefault(digit, []).append(word)
    return out


_WORDS_FOR_DIGIT = _invert_number_words()


class ScriptedRecognizer(object):
    """Emits lines from a script file instead of decoding audio. TEST ONLY.

    This is what makes the pipeline provable without a speech model: with a
    replayed pcap and a scripted transcript, tap -> demux -> gate -> matcher ->
    resolver -> recorder -> counters all run for real, and the only simulated
    component is the one that needs a 40 MB model and a live trunk.

    It ignores the audio entirely and paces itself off it: one script line per
    ~2 seconds of audio accepted, which is roughly an utterance. The daemon
    REFUSES to combine this with PHRASEGUARD_ENFORCE=1 -- a scripted
    recogniser that could disconnect calls is a foot-gun with no legitimate
    use.
    """
    available = True

    def __init__(self, lines, seconds_per_line=2.0):
        self.lines = list(lines)
        self.seconds_per_line = seconds_per_line
        self.audio_seconds = 0.0
        self.decode_seconds = 0.0
        self._emitted = 0

    def accept(self, pcm):
        self.audio_seconds += len(pcm) / float(SAMPLE_RATE * 2)
        want = int(self.audio_seconds / self.seconds_per_line)
        if want <= self._emitted or self._emitted >= len(self.lines):
            return None
        line = self.lines[self._emitted]
        self._emitted += 1
        return (line, 0.99)

    def final(self):
        return None

    def close(self):
        pass


def load_script(path):
    with open(path, "r", encoding="utf-8") as fh:
        return [ln.strip() for ln in fh if ln.strip() and not ln.startswith("#")]


class RecognizerFactory(object):
    """Loads the model once, hands out per-stream recognisers.

    Every failure path here returns a NullRecognizer. There is no path that
    raises out of this object once it is constructed, because the caller is a
    packet loop on a box carrying customer traffic.
    """

    def __init__(self, model_path, corpus, use_grammar=True, script=None):
        self.model_path = model_path
        self.corpus = corpus
        self.use_grammar = use_grammar
        self.script = script
        self.model = None
        self.grammar = None
        self.status = "not loaded"
        self.grammar_supported = None

    def load(self):
        if self.script:
            self.status = ("SCRIPTED recogniser: %d line(s) from %s -- TEST "
                           "ONLY, no audio is decoded"
                           % (len(self.script), "<script>"))
            return True
        vosk = _import_vosk()
        if vosk is None:
            self.status = ("vosk not installed (%s) -- detection DISABLED, "
                           "calls unaffected" % _vosk_error)
            return False
        if not self.model_path or not os.path.isdir(self.model_path):
            self.status = ("model directory not found: %r -- detection "
                           "DISABLED, calls unaffected" % self.model_path)
            return False
        # A model without Gr.fst cannot honour a grammar. Vosk does not fail
        # in that case, it silently ignores the grammar and decodes open
        # vocabulary at roughly ten times the CPU. Detecting it here is the
        # difference between "slower than expected" and a box that runs out
        # of cores under load with no explanation in any log.
        self.grammar_supported = any(
            os.path.exists(os.path.join(self.model_path, *parts))
            for parts in (("graph", "Gr.fst"), ("Gr.fst",)))
        try:
            self.model = vosk.Model(self.model_path)
        except Exception as e:                         # noqa: BLE001
            self.status = "model load failed: %s -- detection DISABLED" % e
            return False
        if self.use_grammar:
            self.grammar = build_grammar(self.corpus)
        note = ""
        if self.use_grammar and not self.grammar_supported:
            note = ("  WARNING: this model has no Gr.fst; the grammar will be "
                    "IGNORED and CPU will be ~10x. Use a model built with a "
                    "grammar, e.g. vosk-model-small-en-us-0.15.")
        self.status = "vosk model loaded from %s%s" % (self.model_path, note)
        return True

    def new(self):
        if self.script:
            return ScriptedRecognizer(self.script)
        if self.model is None:
            return NullRecognizer(self.status)
        try:
            return VoskRecognizer(self.model, self.grammar)
        except Exception as e:                         # noqa: BLE001
            return NullRecognizer("recogniser construction failed: %s" % e)


# ---------------------------------------------------------------------------
# --bench : the phase 3 measurement
# ---------------------------------------------------------------------------
def _bench(factory, seconds, streams):
    """Measure realtime factor, and from it cores per concurrent stream.

    Realtime factor is decode-seconds per audio-second for ONE stream. Cores
    per concurrent stream is the same number: a stream produces audio in real
    time, so a stream whose RTF is 0.25 keeps a quarter of a core busy
    forever. Sizing is then arithmetic against the concurrency the box
    actually sees.
    """
    try:
        from .tap import decode_g711
    except ImportError:
        from tap import decode_g711
    import math
    import random

    # Synthetic speech-band audio. Vosk's cost is dominated by frame count and
    # lattice size, not by whether the audio means anything, so this measures
    # the right thing without a recording of a real call existing anywhere.
    rnd = random.Random(1)
    frames = []
    for n in range(50):
        buf = bytearray()
        for i in range(160):
            v = int(2000 * math.sin(2 * math.pi * 240 * i / 8000.0)
                    + rnd.gauss(0, 400))
            v = max(-32000, min(32000, v))
            buf.append(_lin2ulaw(v))
        frames.append(decode_g711(bytes(buf)))

    print()
    print("=" * 74)
    print("PHRASEGUARD ASR BENCHMARK")
    print("=" * 74)
    print("  %s" % factory.status)
    if factory.model is None:
        print()
        print("  Cannot measure without a model. Install vosk and a model, then")
        print("  re-run. This is the phase 3 checkpoint and it is a MEASUREMENT,")
        print("  not an estimate -- do not size the fleet from a guess.")
        return 1
    print("  grammar words: %d"
          % (len(json.loads(factory.grammar)) if factory.grammar else 0))
    print("  grammar honoured by this model: %s" % factory.grammar_supported)
    print()

    for nstream in streams:
        recs = [factory.new() for _ in range(nstream)]
        if any(not r.available for r in recs):
            print("  recogniser construction failed; aborting")
            return 1
        nframes = int(seconds / 0.02)
        t0 = time.time()
        for n in range(nframes):
            pcm = frames[n % len(frames)]
            for r in recs:
                r.accept(pcm)
        wall = time.time() - t0
        audio = nstream * nframes * 0.02
        decode = sum(r.decode_seconds for r in recs)
        for r in recs:
            r.close()
        rtf = decode / audio if audio else 0
        print("  %3d stream(s)  audio=%6.1fs  decode=%6.2fs  wall=%6.2fs"
              % (nstream, audio, decode, wall))
        print("                 realtime factor = %.4f  ->  %.4f cores per "
              "concurrent stream" % (rtf, rtf))
        if rtf > 0:
            print("                 %d concurrent streams needs %.1f core(s); "
                  "150 needs %.1f" % (62, 62 * rtf, 150 * rtf))
        print()
    print("  Compare against the box: PhraseGuard must fit in the headroom that")
    print("  is left AFTER Asterisk's own relay load at peak, not in the total.")
    print("  If it does not, run the recogniser on a sidecar -- the tap can ship")
    print("  gated PCM over a socket and the SBC keeps only the capture cost.")
    return 0


def _lin2ulaw(sample):
    BIAS, CLIP = 0x84, 32635
    sign = 0
    if sample < 0:
        sample, sign = -sample, 0x80
    sample = min(sample, CLIP) + BIAS
    exp, mask = 7, 0x4000
    while exp > 0 and not (sample & mask):
        exp -= 1
        mask >>= 1
    return ~(sign | (exp << 4) | ((sample >> (exp + 3)) & 0x0F)) & 0xFF


def main(argv=None):
    import argparse
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--corpus", default=os.path.join(here, "phrases.csv"))
    ap.add_argument("--langs", default=os.environ.get("PHRASEGUARD_LANGS", "en"))
    ap.add_argument("--model", default=os.environ.get("PHRASEGUARD_VOSK_MODEL", ""))
    ap.add_argument("--grammar", action="store_true", help="print the grammar and exit")
    ap.add_argument("--bench", action="store_true")
    ap.add_argument("--bench-seconds", type=float, default=30.0)
    ap.add_argument("--bench-streams", default="1,4,16")
    a = ap.parse_args(argv)

    corpus = Corpus(a.corpus, tuple(x.strip() for x in a.langs.split(",") if x.strip()))
    corpus.load()

    if a.grammar:
        g = json.loads(build_grammar(corpus))
        print("%d grammar entries from %d phrase(s)" % (len(g), len(corpus.phrases)))
        print(json.dumps(g, indent=1))
        return 0

    factory = RecognizerFactory(a.model, corpus)
    factory.load()
    if a.bench:
        return _bench(factory, a.bench_seconds,
                      [int(x) for x in a.bench_streams.split(",") if x.strip()])
    print(factory.status)
    return 0 if factory.model is not None else 1


if __name__ == "__main__":
    sys.exit(main())
