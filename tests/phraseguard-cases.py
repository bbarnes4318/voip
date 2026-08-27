#!/usr/bin/env python3
"""Behavioural assertions for PhraseGuard. Driven by run-phraseguard-tests.sh.

Everything here runs offline: no Asterisk, no trunk, no speech model, no
network. That is the point — the parts of PhraseGuard that CAN be proven
without the box are proven every time, so the only things left waiting for
live traffic are the ones that genuinely need it.

Each case states what it is defending. A test whose failure message does not
say what broke is a test that gets deleted the first time it goes red.
"""
import os
import sys

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_ROOT, "phraseguard"))

from matcher import (BScorer, CallWindow, Corpus, Matcher,  # noqa: E402
                     Thresholds, levenshtein, normalize)
from matcher import _build_index as build_index             # noqa: E402
from metaphone import phonetic_equal                        # noqa: E402

CORPUS_PATH = os.path.join(_ROOT, "phraseguard", "phrases.csv")

_PASS = []
_FAIL = []


def check(name, cond, detail=""):
    if cond:
        _PASS.append(name)
    else:
        _FAIL.append((name, detail))


def matches(matcher, text):
    w = CallWindow()
    first = w.add(text)
    return w, matcher.match(w.tokens, since=first)


def tiers_of(ms):
    return [(m.tier, m.phrase.category, m.phrase.text) for m in ms]


def has(ms, tier=None, category=None, phrase=None):
    for m in ms:
        if tier and m.tier != tier:
            continue
        if category and m.phrase.category != category:
            continue
        if phrase and m.phrase.text != phrase:
            continue
        return m
    return None


def run():
    corpus = Corpus(CORPUS_PATH, ("en",))
    corpus.load()
    m = Matcher(corpus, Thresholds())

    # -- normalisation ------------------------------------------------------
    check("normalize folds number words to digits",
          normalize("the six digit code") == ["the", "6", "digit", "code"],
          repr(normalize("the six digit code")))
    check("normalize deletes apostrophes rather than splitting on them",
          normalize("don't tell") == ["dont", "tell"],
          repr(normalize("don't tell")))
    check("normalize strips punctuation and collapses whitespace",
          normalize("  GIFT-CARD,   please!! ") == ["gift", "card", "please"],
          repr(normalize("  GIFT-CARD,   please!! ")))
    check("normalize drops the recogniser's [unk] token",
          normalize("buy a [unk] gift card") == ["buy", "a", "gift", "card"],
          repr(normalize("buy a [unk] gift card")))

    # -- levenshtein cap ----------------------------------------------------
    check("levenshtein returns cap+1 rather than the true distance past cap",
          levenshtein("abcdefghij", "zzzzzzzzzz", 3) == 4)
    check("levenshtein is exact within the cap",
          levenshtein("gift card", "gift cart", 3) == 1)

    # -- phonetics ----------------------------------------------------------
    for a, b in [("anydesk", "any disc"), ("anydesk", "anydisk"),
                 ("teamviewer", "team viewer"), ("logmein", "log me in")]:
        check("phonetic: %r == %r" % (a, b), phonetic_equal(a, b))
    check("phonetic: anydesk != any death", not phonetic_equal("anydesk", "any death"))

    # -- Tier A, exact ------------------------------------------------------
    _w, ms = matches(m, "i need you to buy a gift card at the store")
    check("A2 gift card fires at Tier A", has(ms, tier="A", category="A2"),
          tiers_of(ms))

    _w, ms = matches(m, "please download any disc so i can see your screen")
    hit = has(ms, tier="A", category="A1")
    check("A1 fires on a phonetically mangled brand noun", hit, tiers_of(ms))
    check("A1 phonetic hit is reported as how=phonetic",
          hit and hit.how == "phonetic", hit.how if hit else None)

    _w, ms = matches(m, "read me the 6 digit code we just sent")
    check("A7 matches with digits where the corpus has words",
          has(ms, tier="A", category="A7"), tiers_of(ms))

    # -- Tier A, fuzzy ------------------------------------------------------
    _w, ms = matches(m, "do not tel the bank about this")
    check("A6 survives a one-character recogniser error",
          has(ms, tier="A", category="A6"), tiers_of(ms))

    _w, ms = matches(m, "just go and buy a gift cart")
    hit = has(ms, category="A2")
    check("a near-miss pair lands at A-near, not A",
          hit and hit.tier == "A-near", hit.tier if hit else None)

    # -- THE EXCLUSION VETO -------------------------------------------------
    # The most important assertions in the file. These are questions a
    # licensed insurance agent asks on a legitimate final-expense call, and
    # they sit inside the edit distance of A7's credential-harvesting phrases.
    # A regression here scores legitimate calls on the trunk this box exists
    # to carry.
    #
    # The two lists are separated on purpose. The first are lines that ONLY
    # stay clean because Tier X vetoes them -- each one is verified below to
    # fire without the veto, so this is a real assertion and not a line that
    # happened to be far enough away from the corpus anyway. The second are
    # lines that are clean regardless; they are still worth asserting as a
    # regression net on the corpus, but they prove nothing about the veto.
    veto_dependent = [
        "can i get the last four of your social security number",
        "verify the last four digits of your social security number",
    ]
    stripped = Corpus(CORPUS_PATH, ("en",))
    stripped.load()
    stripped.phrases = [p for p in stripped.phrases if p.tier != "X"]
    stripped.by_index = build_index(stripped.phrases)
    no_veto = Matcher(stripped, Thresholds())

    for legit in veto_dependent:
        _w, ms = matches(m, legit)
        check("exclusion vetoes: %r" % legit[:46],
              not [x for x in ms if x.tier in ("A", "A-near")], tiers_of(ms))
        _w, ms2 = matches(no_veto, legit)
        check("...and it WOULD have scored without Tier X: %r" % legit[:34],
              [x for x in ms2 if x.tier in ("A", "A-near")],
              "nothing fired even without the veto -- this case no longer "
              "tests anything")

    for legit in ["what is your date of birth",
                  "and your zip code please",
                  "who is your beneficiary",
                  "can you confirm your height and weight"]:
        _w, ms = matches(m, legit)
        check("legitimate qualifier stays clean: %r" % legit,
              not [x for x in ms if x.tier in ("A", "A-near")], tiers_of(ms))

    _w, ms = matches(m, "i need your full social security number right now")
    check("the A7 phrase the exclusions protect still fires on its own",
          has(ms, tier="A", category="A7"), tiers_of(ms))

    # -- legitimate insurance script must stay clean ------------------------
    clean = [
        "hi this is a licensed insurance agent calling about final expense",
        "we are not affiliated with any government agency",
        "this call may be recorded for quality and training purposes",
        "there is no obligation and a licensed agent will call you back",
        "can you confirm your date of birth and the last four of your social",
        "do you currently have medicare part a and part b",
    ]
    for line in clean:
        _w, ms = matches(m, line)
        bad = [x for x in ms if x.tier in ("A", "A-near")]
        check("legitimate insurance line stays clean: %r" % line[:44],
              not bad, tiers_of(bad))

    # -- Tier B scoring -----------------------------------------------------
    scorer = BScorer(threshold=2.0, c1_weight=1.5, c2_weight=0.5)
    w = CallWindow()
    for line in ["this is officer johnson badge number four four seven",
                 "this is your final notice"]:
        first = w.add(line)
        for x in m.match(w.tokens, since=first):
            if w.accept(x):
                w.record(x)
    fired, score, cats, _sup = scorer.should_fire(w)
    check("two distinct B categories fire the B threshold", fired,
          "score=%s cats=%s" % (score, cats))
    check("B1 and B2 were the contributing categories",
          cats == {"B1", "B2"}, cats)

    fired2, _s, _c, _u = scorer.should_fire(w)
    check("the B threshold does not re-fire without a new category", not fired2)

    # -- Tier C suppression -------------------------------------------------
    w = CallWindow()
    for line in ["we are not affiliated with any government agency",
                 "this is officer johnson badge number four four seven",
                 "this is your final notice"]:
        first = w.add(line)
        for x in m.match(w.tokens, since=first):
            if w.accept(x):
                w.record(x)
    fired, score, cats, sup = scorer.should_fire(w)
    check("the C1 government disclaimer suppresses the same B pair",
          not fired, "score=%s cats=%s sup=%s" % (score, cats, sup))
    check("C1 was recorded as the suppressor", "C1" in sup, sup)

    # -- one utterance is one event -----------------------------------------
    w = CallWindow()
    reported = []
    for line in ["do not tell the bank tell them it is for a home renovation",
                 "so anyway that is the plan for today"]:
        first = w.add(line)
        for x in m.match(w.tokens, since=first):
            if w.accept(x):
                reported.append(x.phrase.text)
    dupes = [p for p in set(reported) if reported.count(p) > 1]
    check("a phrase absorbing a later token does not re-report", not dupes,
          "duplicated: %s" % dupes)

    # -- a genuine repeat later in the call DOES count ----------------------
    w = CallWindow(window_s=90.0)
    n = 0
    for i, line in enumerate(["you need to buy a gift card",
                              "so again please buy a gift card today"]):
        first = w.add(line, now=1000.0 + i * 30)
        for x in m.match(w.tokens, since=first):
            if w.accept(x) and x.phrase.category == "A2":
                n += 1
    check("the same phrase said twice counts twice", n == 2, "counted %d" % n)

    # -- window eviction ----------------------------------------------------
    w = CallWindow(window_s=10.0)
    w.add("this is officer", now=1000.0)
    w.add("and here is some later speech entirely", now=1100.0)
    check("tokens outside the rolling window are evicted",
          "officer" not in w.tokens, w.tokens)
    check("eviction is accounted for in the dropped offset",
          w.dropped == 3, w.dropped)

    # -- context window -----------------------------------------------------
    w, ms = matches(
        m, "one two three four five six seven eight nine ten "
           "buy a gift card "
           "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu")
    hit = has(ms, category="A2")
    ctx = w.context(hit) if hit else ""
    check("context is bounded to +/-10 words either side",
          hit and len(ctx.split()) <= len(hit.span.split()) + 20,
          "%d words" % len(ctx.split()))

    # -- corpus hot reload keeps the old corpus on a bad file ---------------
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False) as fh:
        fh.write("> tier,category,lang,anchor,phrase,notes\n")
        fh.write("A,A2,en,pair,gift card,\n")
        tmp = fh.name
    c2 = Corpus(tmp, ("en",))
    c2.load()
    before = len(c2.phrases)
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("> tier,category,lang,anchor,phrase,notes\n")
        fh.write("NOPE,this is not,a valid,row\n")
    os.utime(tmp, (0, 0))
    ok, msg = c2.reload_if_changed(force=True)
    check("a corrupt corpus reload is refused", not ok, msg)
    check("a refused reload keeps the previously loaded phrases",
          len(c2.phrases) == before, len(c2.phrases))
    check("the refusal explains itself", msg and "REFUSED" in msg, msg)
    os.unlink(tmp)

    # -- REGRESSION: phonetics must not fire on ordinary English ------------
    # phonetic_key strips whitespace, which is what makes "any disc" the same
    # entry as "anydesk" -- and also made it the same entry as "and ask".
    # "come in and ask for the manager" scored A1 at 1.000, so with
    # enforcement on it would have disconnected a legitimate call. Any change
    # to brand matching has to keep both halves of this true.
    for ordinary in ["come in and ask for the manager",
                     "go on and ask them about the plan",
                     "let me put you on hold and ask my supervisor",
                     "i can call back and ask about that"]:
        _w, ms = matches(m, ordinary)
        check("ordinary English does not phonetically hit a brand: %r"
              % ordinary[:38],
              not [x for x in ms if x.tier == "A"], tiers_of(ms))
    for real in ["please download any disc so i can see your screen",
                 "install anydesk from the link i sent",
                 "open up team viewer for me"]:
        _w, ms = matches(m, real)
        check("the real brand noun still fires: %r" % real[:38],
              has(ms, tier="A", category="A1"), tiers_of(ms))

    # -- REGRESSION: incremental matching must equal batch matching ---------
    # The daemon feeds ONE utterance at a time and passes `since`, so the
    # matcher only scores spans ending at or after the new tokens. The wake
    # scan behind that has to reach back as far as the spans do; when it
    # reached back only one token, three Tier A phrases -- including A1
    # "log me in" -- never fired in production and every offline test still
    # passed, because tests match whole utterances with since=0.
    never = []
    for p in corpus.phrases:
        w = CallWindow()
        fired = False
        for tok in p.tokens:
            first = w.add(tok)
            if any(x.phrase.row == p.row
                   for x in m.match(w.tokens, since=first,
                                    include_exclusions=True)):
                fired = True
        if not fired:
            never.append("%s %r" % (p.category, p.text))
    check("every phrase matches when fed one token at a time", not never,
          "%d phrase(s) never fire incrementally: %s" % (len(never), never[:5]))

    # -- REGRESSION: the B scorer must re-fire in a later window ------------
    # fired_categories used to accumulate for the life of the call, so a floor
    # that read the same script twice in a twenty-minute call registered ONE
    # b_event -- and b_per_1k, the rate the trunk-suspension argument rests
    # on, undercounted exactly the longest calls.
    w = CallWindow(window_s=90.0)
    fires = 0
    for i, t in enumerate([1000.0, 1001.0, 3000.0, 3001.0]):
        line = ["this is officer johnson badge number four four seven",
                "this is your final notice"][i % 2]
        first = w.add(line, now=t)
        for x in m.match(w.tokens, since=first):
            if w.accept(x):
                w.record(x, now=t)
        if scorer.should_fire(w)[0]:
            fires += 1
    check("the same script twice in a long call fires twice", fires == 2,
          "fired %d time(s)" % fires)

    # -- thresholds are configuration, not constants ------------------------
    strict = Matcher(corpus, Thresholds(kill=0.99, review=0.98,
                                        pair_kill=0.99, pair_review=0.98))
    _w, ms = matches(strict, "do not tel the bank about this")
    check("raising the kill threshold demotes a fuzzy hit",
          not has(ms, tier="A", category="A6"), tiers_of(ms))

    return _PASS, _FAIL


def main():
    passed, failed = run()
    for name, detail in failed:
        print("  FAIL  %s" % name)
        if detail:
            print("        got: %s" % (detail,))
    print("  %d passed, %d failed" % (len(passed), len(failed)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
