#!/usr/bin/env python3
"""PhraseGuard corpus loading and phrase matching.

Stdlib only. See metaphone.py for why nothing here pip-installs.

WHAT THIS SOLVES
----------------
8 kHz mu-law telephony audio with heavily accented speech runs 25-40% word
error rate. An exact string match against that misses most of what it should
catch, so every layer here exists to buy back a specific class of recogniser
error:

  normalisation      lowercasing, punctuation, and digit/word folding, so
                     "the 6-digit code" and "the six digit code" are one thing
  edit distance      a Levenshtein budget proportional to phrase length --
                     roughly 2 edits per 10 characters -- which absorbs
                     dropped articles, plurals and mangled short words
  phonetics          Double Metaphone over brand nouns, which is the only
                     thing that reliably catches out-of-vocabulary product
                     names the recogniser has never seen
  anchoring          a single common token is never a Tier A match. Every A
                     entry is a distinctive noun or a phrase of three or more
                     words, enforced by the corpus lint, not by convention
  exclusion veto     legitimate insurance qualifiers ("last four of your
                     social") sit inside the edit distance of Tier A phrases
                     ("your complete social"). Tier X vetoes any match whose
                     token span it overlaps

TWO THRESHOLDS, ALWAYS
----------------------
Every match carries a score, and there are two lines through it. Above the
kill threshold the match is reported at its own tier. Between the review and
kill thresholds a Tier A phrase is reported as tier "A-near": it logs, it
counts toward the Tier B scorer, and it never disconnects anything. Both live
in config. The gap between them is where shadow mode does its work -- an A-near
that turns out to be a real catch argues for lowering the kill threshold; one
that turns out to be a legitimate call argues for demoting the phrase.

COST
----
Matching runs per recognised token, per concurrent stream. A naive loop over
the whole corpus for every token is about 5 cores at this box's peak; the
inverted index below takes that to roughly a quarter of one. See
_build_index() for the trade it makes and what it costs in recall.
"""
import bisect
import csv
import math
import os
import re
import time

try:
    from .metaphone import phonetic_key, phonetic_equal
except ImportError:                                    # run as a script
    from metaphone import phonetic_key, phonetic_equal


# ---------------------------------------------------------------------------
# Normalisation
# ---------------------------------------------------------------------------
# Digit/word folding runs in ONE direction -- words to digits -- on both the
# corpus and the transcript. That is what "expand digits to words and back"
# reduces to once you notice that the only thing that matters is that the two
# sides agree. Folding to digits rather than to words is the cheaper of the
# two because it shortens the string, which tightens the edit budget.
_NUMBER_WORDS = {
    "zero": "0", "oh": "0", "one": "1", "two": "2", "three": "3", "four": "4",
    "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13",
    "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
    "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30",
    "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70",
    "eighty": "80", "ninety": "90", "hundred": "100", "thousand": "1000",
}

# Vosk emits this for out-of-grammar audio. It is not a word and must never
# take part in a span.
_UNK = "[unk]"

_APOSTROPHE = re.compile(r"[’'`]")
_NONWORD = re.compile(r"[^a-z0-9]+")


def normalize(text):
    """Lowercase, strip punctuation, fold number words, return a token list.

    Apostrophes are DELETED rather than replaced with a space: "don't" has to
    become "dont", not "don t", or the corpus entry and the transcript
    disagree about how many tokens the phrase has and the window sizes below
    never line up.
    """
    if not text:
        return []
    text = text.lower().replace(_UNK, " ")
    text = _APOSTROPHE.sub("", text)
    text = _NONWORD.sub(" ", text)
    return [_NUMBER_WORDS.get(t, t) for t in text.split() if t]


# ---------------------------------------------------------------------------
# Levenshtein with a hard cap.
# ---------------------------------------------------------------------------
def levenshtein(a, b, cap):
    """Edit distance between a and b, abandoned once it provably exceeds cap.

    Returns cap + 1 for "further apart than cap". The cap is not an
    optimisation detail -- it is most of the runtime budget. Without it this
    is O(len(a) * len(b)) on every corpus phrase for every recognised token.

    The length precheck is the cheapest rejection there is and fires on the
    large majority of candidate spans.
    """
    if a == b:
        return 0
    la, lb = len(a), len(b)
    if abs(la - lb) > cap:
        return cap + 1
    if la == 0:
        return lb if lb <= cap else cap + 1
    if lb == 0:
        return la if la <= cap else cap + 1

    prev = list(range(lb + 1))
    cur = [0] * (lb + 1)
    for i in range(1, la + 1):
        cur[0] = i
        # Only the diagonal band of width `cap` can hold a value <= cap;
        # everything outside it is already too far and need not be computed.
        lo = max(1, i - cap)
        hi = min(lb, i + cap)
        if lo > 1:
            cur[lo - 1] = cap + 1
        ca = a[i - 1]
        best = cap + 1
        for j in range(lo, hi + 1):
            d = prev[j - 1] if ca == b[j - 1] else prev[j - 1] + 1
            if prev[j] + 1 < d:
                d = prev[j] + 1
            if cur[j - 1] + 1 < d:
                d = cur[j - 1] + 1
            cur[j] = d
            if d < best:
                best = d
        if best > cap:
            return cap + 1
        if hi < lb:
            cur[hi + 1] = cap + 1
        prev, cur = cur, prev
    d = prev[lb]
    return d if d <= cap else cap + 1


# ---------------------------------------------------------------------------
# Corpus
# ---------------------------------------------------------------------------
class Phrase(object):
    __slots__ = ("tier", "category", "lang", "anchor", "text", "notes",
                 "tokens", "joined", "pkey", "triggers", "row")

    def __init__(self, tier, category, lang, anchor, text, notes, row):
        self.tier = tier
        self.category = category
        self.lang = lang
        self.anchor = anchor
        self.text = text
        self.notes = notes
        self.row = row
        self.tokens = normalize(text)
        self.joined = " ".join(self.tokens)
        self.pkey = phonetic_key(self.joined)
        self.triggers = ()

    def __repr__(self):
        return "<Phrase %s/%s %r>" % (self.tier, self.category, self.text)


class CorpusError(Exception):
    pass


# Tokens common enough that a phrase containing one is not worth waking up for
# on its own. Used only to choose trigger tokens for the inverted index; it
# never affects whether a phrase can match.
_STOPWORDS = frozenset("""
a an and are as at be been by for from had has have he her his i if in is it
its me my not of on or our out she that the their them then there these they
this to up us was we were will with you your
""".split())

# The words a Tier A phrase -- or a Tier A MATCH SPAN -- may not be built
# entirely out of. Wider than _STOPWORDS: these are the words that actually
# occur in insurance and lead-generation scripts on this trunk, which is the
# traffic a false positive lands on.
#
# WHY A MATCH SPAN AND NOT JUST A CORPUS ROW. Brand anchors are compared
# phonetically with whitespace REMOVED, which is what makes "anydesk",
# "any desk" and "any disc" one entry. It also makes them the same entry as
# "and ask":
#
#     phonetic_key("any desk") == phonetic_key("and ask") == "ANTSK"
#
# "come in and ask for the manager" therefore scored A1 at 1.000 and, with
# enforcement on, would have disconnected the call. Collapsing word boundaries
# is exactly what buys the accent robustness, so the fix is not to stop doing
# it -- it is to apply the brief's own rule to the span that matched, not only
# to the row it matched against. A span of nothing but common English words is
# never a brand noun, however it is pronounced.
#
# tools/phraseguard-lint.py imports this list rather than keeping its own, so
# the rule the linter enforces and the rule the matcher applies cannot drift.
COMMON_WORDS = frozenset("""
a about after all also am an and any are as ask at back be been before being
best but buy by call called calling can come could day did do does doing done
down each end even for from get give go going good got had has have he her
here him his how i if in into is it its just know last let like little long
look made make man many may me more most my need new no not now number of off
often on once one only or other our out over own people place put said same
say see she should since so some take talk tell than that the their them then
there these they thing think this those three time to today too two up us use
very want was way we well went were what when where which while who why will
with would year yes you your
""".split())


def all_common(tokens):
    """True if every token is an ordinary English word."""
    return bool(tokens) and all(t in COMMON_WORDS for t in tokens)

# A phrase is woken by any of its tokens that appear in at most this many
# corpus phrases. Raising it costs runtime; lowering it costs nothing until a
# phrase has no token below the bar, at which point its single rarest token is
# used regardless. See _build_index().
_TRIGGER_DF_MAX = 12


class Corpus(object):
    """The phrase list, reloadable in place.

    Reload is mtime-driven and additionally forced by SIGHUP (the daemon calls
    reload_if_changed() from its main loop rather than from the handler, so a
    corrupt file cannot be loaded from inside a signal context).

    A failed reload KEEPS THE OLD CORPUS. That is the fail-open rule applied to
    the one component an operator edits by hand at 2am: a corpus with a typo in
    it must not take the detector down, and it must certainly not leave the
    detector running against a half-parsed file.
    """

    def __init__(self, path, langs=("en",)):
        self.path = path
        self.langs = tuple(langs)
        self.phrases = []
        self.by_index = {}
        self.max_span = 4
        self.mtime = 0.0
        self.load_error = None
        self.loaded_at = 0.0
        self.reload_count = 0

    # -- loading ------------------------------------------------------------
    def load(self):
        phrases = []
        seen = set()
        with open(self.path, "r", encoding="utf-8", newline="") as fh:
            for lineno, raw in enumerate(fh, 1):
                line = raw.rstrip("\r\n")
                if not line.strip():
                    continue
                if line.startswith("#"):
                    continue
                if line.startswith(">"):                # the header line
                    continue
                row = next(csv.reader([line]))
                if len(row) < 5:
                    raise CorpusError(
                        "%s:%d: expected at least 5 columns "
                        "(tier,category,lang,anchor,phrase[,notes]), got %d"
                        % (self.path, lineno, len(row)))
                tier = row[0].strip().upper()
                category = row[1].strip().upper()
                lang = row[2].strip().lower()
                anchor = row[3].strip().lower()
                text = row[4].strip()
                notes = row[5].strip() if len(row) > 5 else ""

                if tier not in ("A", "B", "C", "X"):
                    raise CorpusError("%s:%d: unknown tier %r"
                                      % (self.path, lineno, tier))
                if anchor not in ("brand", "pair", "seq"):
                    raise CorpusError("%s:%d: unknown anchor %r"
                                      % (self.path, lineno, anchor))
                if not text:
                    raise CorpusError("%s:%d: empty phrase" % (self.path, lineno))
                if lang not in self.langs:
                    continue

                p = Phrase(tier, category, lang, anchor, text, notes, lineno)
                if not p.tokens:
                    raise CorpusError("%s:%d: phrase %r normalises to nothing"
                                      % (self.path, lineno, text))
                key = (lang, p.joined)
                if key in seen:
                    # Not fatal in principle, but a duplicate means one of the
                    # two rows is dead and the operator cannot tell which. On a
                    # file whose whole job is to be edited by hand, silent dead
                    # rows are how a corpus rots.
                    raise CorpusError(
                        "%s:%d: %r duplicates an earlier row (normalised: %r)"
                        % (self.path, lineno, text, p.joined))
                seen.add(key)
                phrases.append(p)

        if not phrases:
            raise CorpusError("%s: no phrases loaded for languages %s"
                              % (self.path, ",".join(self.langs)))

        self.phrases = phrases
        self.by_index = _build_index(phrases)
        # The widest span any phrase can match, which is how far back the
        # incremental scan in Matcher.match has to look. brand anchors scan up
        # to Thresholds.brand_span tokens; seq/pair go to len+1. Computed once
        # per load rather than per token.
        self.max_span = max([len(p.tokens) + 1 for p in phrases] + [4])
        self.mtime = os.path.getmtime(self.path)
        self.loaded_at = time.time()
        self.load_error = None
        return len(phrases)

    def reload_if_changed(self, force=False):
        """Returns (reloaded, message). Never raises; never drops the corpus."""
        try:
            mtime = os.path.getmtime(self.path)
        except OSError as e:
            self.load_error = str(e)
            return (False, "corpus stat failed, keeping %d loaded phrase(s): %s"
                    % (len(self.phrases), e))
        if not force and mtime == self.mtime and self.phrases:
            return (False, None)

        keep_phrases = self.phrases
        keep_index = self.by_index
        keep_span = self.max_span
        try:
            n = self.load()
        except Exception as e:                          # noqa: BLE001 - fail open
            self.phrases = keep_phrases
            self.by_index = keep_index
            self.max_span = keep_span
            # Record the BROKEN file's mtime, not the last good one. Restoring
            # the old mtime means the guard above can never short-circuit, so
            # the daemon re-parses the same broken file and re-emits the same
            # warning every housekeeping pass -- 5,760 duplicate records a day
            # into an append-only evidence log. Fixing the file changes the
            # mtime again and the retry happens then, which is what "retry on
            # the next change" was supposed to mean.
            self.mtime = mtime
            self.load_error = str(e)
            return (False, "corpus reload REFUSED, keeping %d loaded phrase(s): %s"
                    % (len(keep_phrases), e))
        self.reload_count += 1
        return (True, "corpus loaded: %d phrase(s) from %s" % (n, self.path))

    def counts(self):
        out = {}
        for p in self.phrases:
            out[p.tier] = out.get(p.tier, 0) + 1
        return out


def _build_index(phrases):
    """token key -> list of phrase positions that key should wake up.

    THE TRADE. Evaluating every phrase against every recognised token is about
    5 cores at this box's peak concurrency; only evaluating phrases that share
    a distinctive token with the incoming text is about a quarter of one. What
    it costs is recall in exactly one case: if the recogniser mangles EVERY
    distinctive token of a phrase, the phrase is never woken and the span is
    never scored, however good the rest of the match would have been.

    That is mitigated, not eliminated, by indexing each trigger token under
    both its literal spelling and its Double Metaphone code, so a token has to
    be mangled past phonetic recognition rather than merely misspelled. It is
    the right trade for a keyword spotter -- a phrase whose every distinctive
    word came out unrecognisable was not going to clear the kill threshold
    anyway -- but it IS a trade, and it is the first thing to look at if
    shadow mode shows a phrase that should have fired and did not.
    """
    df = {}
    for p in phrases:
        for t in set(p.tokens):
            df[t] = df.get(t, 0) + 1

    index = {}
    for pos, p in enumerate(phrases):
        uniq = set(p.tokens)
        triggers = [t for t in uniq if t not in _STOPWORDS and df[t] <= _TRIGGER_DF_MAX]
        if not triggers:
            # Every token is either a stopword or too common. Fall back to the
            # rarest token in the phrase, whatever it is -- a phrase that can
            # never be woken is worse than one that is woken often.
            triggers = [min(uniq, key=lambda t: (df[t], t))]
        p.triggers = tuple(sorted(triggers))
        for t in triggers:
            index.setdefault(t, []).append(pos)
            pk = phonetic_key(t)
            if pk and pk != t:
                index.setdefault("~" + pk, []).append(pos)
    for k in index:
        index[k] = sorted(set(index[k]))
    return index


# ---------------------------------------------------------------------------
# Matching
# ---------------------------------------------------------------------------
class Match(object):
    __slots__ = ("phrase", "tier", "score", "start", "end", "span", "how")

    def __init__(self, phrase, tier, score, start, end, span, how):
        self.phrase = phrase
        self.tier = tier              # A, A-near, B, C, X -- reported tier
        self.score = score
        self.start = start            # token index, inclusive
        self.end = end                # token index, exclusive
        self.span = span              # the transcript text that matched
        self.how = how                # "exact" | "edit" | "phonetic"

    @property
    def category(self):
        return self.phrase.category

    def __repr__(self):
        return "<Match %s %s %.2f %r>" % (self.tier, self.phrase.category,
                                          self.score, self.span)


class Thresholds(object):
    """Every number that decides whether a call gets disconnected.

    All of them are config (see config.env.example). None of them is tuned per
    phrase: a phrase that needs its own threshold to behave is a phrase that
    belongs in a lower tier, and the brief says so explicitly.
    """

    def __init__(self, kill=0.86, review=0.72, pair_kill=0.92, pair_review=0.80,
                 edit_ratio=0.20, brand_span=3):
        self.kill = kill
        self.review = review
        self.pair_kill = pair_kill
        self.pair_review = pair_review
        self.edit_ratio = edit_ratio
        self.brand_span = brand_span

    @classmethod
    def from_env(cls, env=None):
        e = os.environ if env is None else env

        def f(name, default):
            try:
                return float(e.get(name, "") or default)
            except (TypeError, ValueError):
                return default

        def i(name, default):
            try:
                return int(e.get(name, "") or default)
            except (TypeError, ValueError):
                return default

        return cls(kill=f("PHRASEGUARD_KILL_SCORE", 0.86),
                   review=f("PHRASEGUARD_REVIEW_SCORE", 0.72),
                   pair_kill=f("PHRASEGUARD_PAIR_KILL_SCORE", 0.92),
                   pair_review=f("PHRASEGUARD_PAIR_REVIEW_SCORE", 0.80),
                   edit_ratio=f("PHRASEGUARD_EDIT_RATIO", 0.20),
                   brand_span=i("PHRASEGUARD_BRAND_SPAN", 3))

    def kill_for(self, phrase):
        return self.pair_kill if phrase.anchor == "pair" else self.kill

    def review_for(self, phrase):
        return self.pair_review if phrase.anchor == "pair" else self.review


class Matcher(object):
    """Scores a token sequence against the corpus.

    Stateless with respect to calls -- per-call state (the rolling window, the
    B score) lives in CallWindow. This object is shared across every concurrent
    stream, so it must stay read-only during matching.
    """

    def __init__(self, corpus, thresholds=None):
        self.corpus = corpus
        self.th = thresholds or Thresholds()

    # -- one span against one phrase ---------------------------------------
    def _score_seq(self, phrase, span_tokens):
        target = phrase.joined
        cand = " ".join(span_tokens)
        if cand == target:
            return 1.0, "exact"
        budget = max(1, int(math.ceil(len(target) * self.th.edit_ratio)))
        d = levenshtein(target, cand, budget)
        if d > budget:
            return 0.0, None
        return max(0.0, 1.0 - float(d) / len(target)), "edit"

    def _score_brand(self, phrase, span_tokens):
        cand = " ".join(span_tokens)
        if cand == phrase.joined:
            return 1.0, "exact"
        # A span of nothing but ordinary English words is not a brand noun,
        # whatever it sounds like. Without this, phonetic_key("and ask") ==
        # phonetic_key("any desk") == "ANTSK" and "come in and ask for the
        # manager" is a Tier A disconnect. See COMMON_WORDS.
        if all_common(span_tokens):
            return 0.0, None
        # Phonetic identity is binary and is the whole point of a brand
        # anchor: it is what makes "any disc" the same entry as "anydesk".
        if phonetic_equal(cand, phrase.joined):
            return 1.0, "phonetic"
        # A brand noun that is neither spelled nor pronounced right can still
        # be close enough to be worth logging, but never close enough to kill.
        s, how = self._score_seq(phrase, span_tokens)
        if how and s > 0:
            return min(s, self.th.review_for(phrase) + 1e-9), how
        return 0.0, None

    # -- the whole transcript window ---------------------------------------
    def match(self, tokens, since=0, include_exclusions=False):
        """Match `tokens`, considering only spans that end at index >= since.

        `since` is what makes this incremental: on each recognised token the
        daemon re-matches only the spans that the new token could have
        completed, not the whole 90-second window.

        Returns matches sorted by (start, -score), with the Tier X veto and
        overlap suppression already applied. Tier X matches are CONSUMED by
        the veto and never returned -- an exclusion is not an event, it is the
        absence of one. include_exclusions=True returns them anyway, which is
        how tools/phraseguard-lint.py checks that an exclusion row can match
        its own text at all.
        """
        n = len(tokens)
        if n == 0:
            return []
        phrases = self.corpus.phrases
        index = self.corpus.by_index

        # Which phrases could possibly match a span ending at or after
        # `since`? Only those woken by a token in that region.
        #
        # THE SCAN MUST REACH BACK AS FAR AS THE SPANS DO. A span ending at
        # `since` can START at `since - max_span + 1`, so a phrase whose only
        # distinctive tokens sit at the FRONT of that span is woken only if
        # the scan reaches them. Scanning from `since - 1` looked right and was
        # not: fed one token at a time -- which is what the daemon does -- A1
        # "log me in" never fired, because its trigger token "log" had already
        # scrolled behind the scan window by the time "in" completed the span.
        # Its last two tokens are stopwords and wake nothing.
        #
        # This is invisible to any test that matches a whole utterance in one
        # call, because `since` is 0 there and the scan starts at 0 regardless.
        wake = set()
        scan_from = max(0, since - self.corpus.max_span)
        for i in range(scan_from, n):
            t = tokens[i]
            hit = index.get(t)
            if hit:
                wake.update(hit)
            pk = phonetic_key(t)
            if pk:
                hit = index.get("~" + pk)
                if hit:
                    wake.update(hit)
        if not wake:
            return []

        raw = []
        for pos in sorted(wake):
            p = phrases[pos]
            plen = len(p.tokens)
            if p.anchor == "brand":
                widths = range(1, self.th.brand_span + 1)
            else:
                # One token of slack either way absorbs a dropped article or a
                # spurious insertion, which is the most common recogniser
                # error on a phrase this short.
                widths = range(max(1, plen - 1), plen + 2)
            best = None
            for w in widths:
                # A span must END at or after `since`, or it was already
                # scored on an earlier token.
                first_start = max(0, since - w + 1)
                for s in range(first_start, n - w + 1):
                    span = tokens[s:s + w]
                    if p.anchor == "brand":
                        score, how = self._score_brand(p, span)
                    else:
                        score, how = self._score_seq(p, span)
                    if not how:
                        continue
                    if best is None or score > best[0]:
                        best = (score, s, s + w, how)
            if best is None:
                continue
            score, s, e, how = best
            review = self.th.review_for(p)
            if score < review:
                continue
            kill = self.th.kill_for(p)
            if p.tier == "A":
                tier = "A" if score >= kill else "A-near"
            elif p.tier in ("B", "C", "X"):
                # B, C and X have no near band. A suppressor or an exclusion
                # that only half-matched must not half-apply: it either counts
                # or it does not, and the conservative reading of "half a
                # not-affiliated disclaimer" is that the floor read it.
                if score < kill:
                    continue
                tier = p.tier
            else:
                continue
            raw.append(Match(p, tier, score, s, e, " ".join(tokens[s:e]), how))

        if not raw:
            return []

        # --- Tier X veto ---------------------------------------------------
        # An exclusion does not merely outrank an A match, it deletes it. The
        # motivating case: "last four of your social" is what a licensed agent
        # asks, and it is inside the edit budget of A7 "your complete social".
        # Overlap is the right test -- the exclusion and the A phrase are
        # competing readings of the SAME audio.
        vetoes = [m for m in raw if m.tier == "X"]
        if vetoes:
            kept = []
            for m in raw:
                if m.tier == "X":
                    if include_exclusions:
                        kept.append(m)
                    continue
                if any(v.start < m.end and m.start < v.end for v in vetoes):
                    continue
                kept.append(m)
            raw = kept

        # --- overlap suppression within a category --------------------------
        # Two corpus entries covering the same span (A2 "gift card" and A2
        # "apple gift card") are one event, not two, and reporting both
        # inflates every per-phrase count in the shadow-mode review.
        #
        # Ties break toward the LONGER span, which is the more specific and
        # more probative phrase. B5 "your grandson" and B5 "your grandson is
        # in jail" both score 1.0 on the same audio; the second is the one
        # worth having in an evidence log, and picking by corpus line order
        # would have picked the first.
        raw.sort(key=lambda m: (-m.score, -(m.end - m.start), m.start,
                                m.phrase.row))
        chosen = []
        for m in raw:
            if any(o.start < m.end and m.start < o.end
                   and o.phrase.category == m.phrase.category for o in chosen):
                continue
            chosen.append(m)
        chosen.sort(key=lambda m: (m.start, -m.score))
        return chosen


# ---------------------------------------------------------------------------
# Per-call rolling window and the Tier B scorer
# ---------------------------------------------------------------------------
class CallWindow(object):
    """A rolling 90-second transcript window for one call.

    Holds tokens and their arrival times, nothing else. No audio, ever -- see
    README.md. The window serves two purposes: the Tier B scorer needs to know
    what else was said recently, and every log record carries a +/-10 word
    context so a human reviewing a shadow-mode hit can see what the phrase was
    embedded in.
    """

    def __init__(self, window_s=90.0, context_words=10, max_tokens=4000):
        self.window_s = window_s
        self.context_words = context_words
        self.max_tokens = max_tokens
        self.tokens = []
        self.times = []
        self.dropped = 0          # tokens evicted so far. Match indices are
                                  # relative to `tokens`; add `dropped` to get
                                  # an ABSOLUTE index that survives eviction.
        self.hits = []            # (ts, tier, category, phrase_text, score)
        self.reported = {}        # phrase row -> [(abs_start, abs_end), ...]
        self.fired_categories = set()
        self.b_events = 0

    def add(self, text, now=None):
        """Append recognised text. Returns the index of the first new token."""
        now = time.time() if now is None else now
        new = normalize(text)
        first = len(self.tokens)
        if not new:
            return first
        self.tokens.extend(new)
        self.times.extend([now] * len(new))
        # Only the tokens evicted BY THIS CALL shift the index. Subtracting the
        # cumulative `dropped` would walk `since` backwards on every call once
        # the window had rolled once, re-matching the whole window each time.
        before = self.dropped
        self._evict(now)
        return max(0, first - (self.dropped - before))

    def accept(self, match):
        """True if this match is new; False if it re-reports one already made.

        THE DUPLICATE THIS PREVENTS. Spans are matched with one token of slack
        either side, so a phrase that already matched can match AGAIN on the
        next utterance by absorbing one new token -- "tell them it is for a
        home renovation" and then "tell them it is for a home renovation i",
        the second at a slightly lower score. Both are the same words said
        once.

        That is not a cosmetic problem. Per-phrase hit counts are the number
        the shadow-mode review uses to decide which Tier A phrases survive,
        and a phrase that double-counts looks twice as trigger-happy as it is.
        It would also double-count against the per-customer rate, which is the
        evidence the commercial conversation runs on.

        Overlap is compared in ABSOLUTE token coordinates so it stays correct
        across window eviction. A genuine second utterance of the same phrase
        later in the call does not overlap and is accepted.
        """
        a0 = self.dropped + match.start
        a1 = self.dropped + match.end
        spans = self.reported.get(match.phrase.row)
        if spans:
            for s0, s1 in spans:
                if s0 < a1 and a0 < s1:
                    return False
        else:
            spans = self.reported[match.phrase.row] = []
        spans.append((a0, a1))
        return True

    def _evict(self, now):
        cutoff = now - self.window_s
        # times is non-decreasing, so the first token to keep is a bisect away.
        keep = bisect.bisect_left(self.times, cutoff)
        # A stream that talks for a long time without pause still must not
        # grow without bound; the token cap is a memory ceiling, not a policy.
        if len(self.tokens) - keep > self.max_tokens:
            keep = len(self.tokens) - self.max_tokens
        if keep > 0:
            self.tokens = self.tokens[keep:]
            self.times = self.times[keep:]
            self.dropped += keep
            # Forget reported spans that have fallen out of the window
            # entirely. A phrase said again after the window has rolled past
            # the first instance is a genuinely new event and must count.
            for row in list(self.reported):
                spans = [s for s in self.reported[row] if s[1] > self.dropped]
                if spans:
                    self.reported[row] = spans
                else:
                    del self.reported[row]
        self.hits = [h for h in self.hits if h[0] >= cutoff]
        # fired_categories has to roll with the window too. Left to accumulate,
        # it is the union of every set that ever fired, so a floor that reads
        # the same script twice in a twenty-minute call registers ONE B event
        # -- and b_per_1k, the rate the trunk-suspension argument is built on,
        # systematically undercounts exactly the longest calls.
        live = {h[2] for h in self.hits}
        if "A-near" in {h[1] for h in self.hits}:
            live.add("A-near")
        self.fired_categories &= live

    def context(self, match):
        lo = max(0, match.start - self.context_words)
        hi = min(len(self.tokens), match.end + self.context_words)
        return " ".join(self.tokens[lo:hi])

    def record(self, match, now=None):
        now = time.time() if now is None else now
        self.hits.append((now, match.tier, match.phrase.category,
                          match.phrase.text, match.score))


class BScorer(object):
    """Turns Tier B and A-near hits in a window into a threshold event.

    THE RULE, from the brief: fire on two distinct B categories inside the
    rolling window, or one B plus a near-miss A. Tier C reduces the score.

    Counting distinct CATEGORIES rather than distinct phrases is deliberate.
    A floor that says "social security administration", "office of inspector
    general" and "badge number" in one breath has said one thing three ways --
    it is a single B1 signal -- and counting it as three would clear the
    threshold on agency impersonation alone, which is precisely the reading
    that makes a compliant Medicare agent look like a scammer.

    C1 (the not-affiliated-with-any-government-agency disclaimer) is weighted
    separately and heavily. It is the highest-value suppressor in the corpus
    because it is read by floors with a compliance script and by no scam floor
    ever, and the categories it most often coincides with -- B1 agency names,
    B2 urgency -- are exactly the ones a legitimate Medicare campaign trips.
    """

    def __init__(self, threshold=2.0, c1_weight=1.5, c2_weight=0.5,
                 max_suppress=2.0):
        self.threshold = threshold
        self.c1_weight = c1_weight
        self.c2_weight = c2_weight
        self.max_suppress = max_suppress

    @classmethod
    def from_env(cls, env=None):
        e = os.environ if env is None else env

        def f(name, default):
            try:
                return float(e.get(name, "") or default)
            except (TypeError, ValueError):
                return default

        return cls(threshold=f("PHRASEGUARD_B_THRESHOLD", 2.0),
                   c1_weight=f("PHRASEGUARD_C1_WEIGHT", 1.5),
                   c2_weight=f("PHRASEGUARD_C2_WEIGHT", 0.5),
                   max_suppress=f("PHRASEGUARD_C_MAX_SUPPRESS", 2.0))

    def score(self, window):
        """Returns (score, contributing_categories, suppressing_categories)."""
        contributing = set()
        suppressing = set()
        for _ts, tier, category, _text, _score in window.hits:
            if tier == "B":
                contributing.add(category)
            elif tier == "A-near":
                # One pseudo-category, however many distinct A phrases nearly
                # matched. Three near-misses on three A5 phrases is one signal.
                contributing.add("A-near")
            elif tier == "C":
                suppressing.add(category)
        raw = float(len(contributing))
        suppress = 0.0
        for c in suppressing:
            suppress += self.c1_weight if c == "C1" else self.c2_weight
        suppress = min(suppress, self.max_suppress)
        return max(0.0, raw - suppress), contributing, suppressing

    def should_fire(self, window):
        """True when the window has newly crossed the threshold.

        "Newly" matters: without it a call that crosses the line keeps firing
        on every subsequent token for the rest of the window, and the per-
        customer counters -- the actual deliverable of this whole component --
        end up counting recogniser tokens instead of calls. Re-firing requires
        a category that was not part of the set that fired last time.
        """
        score, contributing, suppressing = self.score(window)
        if score < self.threshold:
            return (False, score, contributing, suppressing)
        if contributing <= window.fired_categories:
            return (False, score, contributing, suppressing)
        window.fired_categories |= contributing
        window.b_events += 1
        return (True, score, contributing, suppressing)


def load_corpus(path, langs=("en",), thresholds=None):
    """Convenience: load a corpus and return (corpus, matcher)."""
    c = Corpus(path, langs)
    c.load()
    return c, Matcher(c, thresholds)


if __name__ == "__main__":
    import sys
    _path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "phrases.csv")
    _c, _m = load_corpus(_path)
    print("loaded %d phrase(s) from %s" % (len(_c.phrases), _path))
    print("tiers: %s" % _c.counts())
    print("index keys: %d" % len(_c.by_index))
    if len(sys.argv) > 2:
        _w = CallWindow()
        _text = " ".join(sys.argv[2:])
        _first = _w.add(_text)
        for _mt in _m.match(_w.tokens, since=_first):
            print("  %-7s %-4s %.3f %-9s %-40r  ctx=%r"
                  % (_mt.tier, _mt.category, _mt.score, _mt.how,
                     _mt.phrase.text, _w.context(_mt)))
