#!/usr/bin/env python3
"""Validate phraseguard/phrases.csv, and prove the corpus matches itself.

Run this after ANY edit to the corpus, and in the test suite. It is fast and
it catches the two classes of mistake that a data file edited by hand at 2am
actually produces:

  a rule broken quietly   a Tier A phrase built out of common words, which
                          disconnects legitimate calls
  a row that is dead      a phrase whose normalised form cannot match its own
                          text, which never fires and is never noticed

THE RULES, and why each one exists
----------------------------------
1.  Schema. Five or six columns, known tier, known anchor, non-empty phrase.

2.  Tier A anchoring. The brief's rule is "a single common token is never a
    Tier A phrase; every A entry is either a distinctive brand noun or a
    phrase of three or more words." That is enforced as:
        anchor=seq    3 or more tokens
        anchor=brand  1-2 tokens, none of them a common English word
        anchor=pair   exactly 2 tokens, at least one uncommon
    A row whose anchor and shape disagree is an error, not a warning: the
    anchor decides how it is matched, so a wrong one is a phrase being matched
    by rules it was not written for.

3.  No non-English row may be Tier A. The ur set is a SEED for native-speaker
    review. Machine-generated transliterations are not authoritative, an
    English acoustic model renders them unpredictably, and a wrong Tier A row
    in a language nobody reviewing the logs reads disconnects a legitimate
    call invisibly. Promotion to A is a human decision after review.

4.  Self-match. Every phrase, fed its own text, must come back at its own tier
    with score 1.0. This is the check that catches a normalisation bug, a
    stray character, or a phrase whose tokens the anchor cannot span.

5.  Tier X reachability. Every exclusion must actually veto something -- an
    exclusion that overlaps no A or B phrase is either a typo or a phrase
    that was demoted out from under it.

  ./phraseguard-lint.py                    lint the tracked corpus
  ./phraseguard-lint.py --corpus PATH      lint another file
  ./phraseguard-lint.py --langs en,ur      include the seed languages
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_PG = os.path.join(os.path.dirname(_HERE), "phraseguard")
if _PG not in sys.path:
    sys.path.insert(0, _PG)

from matcher import COMMON_WORDS, Corpus, Matcher, Thresholds  # noqa: E402

# The common-word list lives in matcher.py and is imported, not restated.
#
# The matcher applies it at RUNTIME, to reject a Tier A brand span built only
# out of ordinary English -- that is what stops "come in and ask for the
# manager" being scored as AnyDesk. This linter applies the same list to
# corpus ROWS, so a phrase with that shape is caught at edit time instead.
#
# Two hand-maintained copies would eventually disagree, and the failure mode of
# disagreement is precisely a row that passes the lint and then disconnects
# legitimate calls.
COMMON = COMMON_WORDS


class Finding(object):
    def __init__(self, level, row, message):
        self.level = level
        self.row = row
        self.message = message


def lint(corpus_path, langs):
    findings = []
    corpus = Corpus(corpus_path, langs)
    try:
        n = corpus.load()
    except Exception as e:                             # noqa: BLE001
        return None, [Finding("ERROR", 0, "corpus will not load: %s" % e)]

    # --- rule 2: Tier A anchoring ------------------------------------------
    for p in corpus.phrases:
        ntok = len(p.tokens)
        uncommon = [t for t in p.tokens if t not in COMMON]
        if p.tier == "A":
            if p.anchor == "seq" and ntok < 3:
                findings.append(Finding(
                    "ERROR", p.row,
                    "Tier A anchor=seq %r has %d token(s); seq requires 3 or "
                    "more. Either it is a brand noun (anchor=brand), a "
                    "distinctive pair (anchor=pair), or it does not belong in "
                    "Tier A." % (p.text, ntok)))
            if p.anchor == "brand":
                if ntok > 2:
                    findings.append(Finding(
                        "ERROR", p.row,
                        "Tier A anchor=brand %r has %d tokens; brand is for "
                        "1-2 token proper/product nouns." % (p.text, ntok)))
                if not uncommon:
                    findings.append(Finding(
                        "ERROR", p.row,
                        "Tier A anchor=brand %r is built only from common "
                        "English words. A brand anchor is matched "
                        "phonetically, so this would disconnect on ordinary "
                        "speech." % p.text))
            if p.anchor == "pair":
                if ntok != 2:
                    findings.append(Finding(
                        "ERROR", p.row,
                        "Tier A anchor=pair %r has %d token(s); pair is "
                        "exactly 2." % (p.text, ntok)))
                if not uncommon:
                    findings.append(Finding(
                        "ERROR", p.row,
                        "Tier A anchor=pair %r is two common English words. "
                        "That is the 'single common token' rule in its most "
                        "dangerous form." % p.text))
        # --- rule 3: no unreviewed language at Tier A ----------------------
        if p.lang != "en" and p.tier == "A":
            findings.append(Finding(
                "ERROR", p.row,
                "%r is lang=%s at Tier A. Non-English rows ship as seeds for "
                "native-speaker review and must not disconnect calls until a "
                "human has confirmed both the wording and how the recogniser "
                "actually spells it." % (p.text, p.lang)))
        if p.lang != "en" and "SEED" not in (p.notes or "").upper():
            findings.append(Finding(
                "WARN", p.row,
                "%r is lang=%s but is not marked SEED in notes. Mark reviewed "
                "rows explicitly so the unreviewed ones stay visible."
                % (p.text, p.lang)))
        # A phrase that normalises to nothing cannot reach here: Corpus.load
        # raises CorpusError on it before the row is ever appended.

    # --- rule 4: self-match -------------------------------------------------
    matcher = Matcher(corpus, Thresholds.from_env())
    for p in corpus.phrases:
        # p.tokens IS normalize(p.text), computed once in Phrase.__init__.
        # include_exclusions, or every Tier X row reads as "can never fire":
        # the veto consumes X matches before they are returned, by design.
        hits = matcher.match(p.tokens, since=0, include_exclusions=True)
        mine = [h for h in hits if h.phrase.row == p.row]
        if not mine:
            competing = ", ".join(
                "%s/%s %r" % (h.tier, h.category, h.phrase.text) for h in hits[:3])
            findings.append(Finding(
                "ERROR", p.row,
                "%r does not match its own text. It can never fire.%s"
                % (p.text, (" Shadowed by: " + competing) if competing else "")))
            continue
        best = max(mine, key=lambda h: h.score)
        if best.score < 0.999:
            findings.append(Finding(
                "WARN", p.row,
                "%r self-matches at only %.3f; expected 1.000. Check the "
                "normalised form %r." % (p.text, best.score, p.joined)))
        # A row must self-match at its OWN tier. In particular a Tier A row
        # coming back as "A-near" means it cannot reach its own kill
        # threshold even on a perfect transcript.
        want = p.tier
        if best.tier != want:
            findings.append(Finding(
                "ERROR", p.row,
                "%r self-matches as tier %s, not %s."
                % (p.text, best.tier, want)))

    # --- rule 5: Tier X reachability ---------------------------------------
    exclusions = [p for p in corpus.phrases if p.tier == "X"]
    ab = [p for p in corpus.phrases if p.tier in ("A", "B")]
    for x in exclusions:
        xt = set(x.tokens)
        if not any(xt & set(p.tokens) for p in ab):
            findings.append(Finding(
                "WARN", x.row,
                "exclusion %r shares no token with any A or B phrase. It "
                "vetoes nothing -- either the phrase it was protecting has "
                "been demoted, or this is a typo." % x.text))

    return corpus, findings


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--corpus", default=os.path.join(_PG, "phrases.csv"))
    ap.add_argument("--langs", default="en")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args(argv)

    langs = tuple(x.strip() for x in a.langs.split(",") if x.strip())
    corpus, findings = lint(a.corpus, langs)

    errors = [f for f in findings if f.level == "ERROR"]
    warns = [f for f in findings if f.level == "WARN"]

    if not a.quiet:
        print()
        print("phraseguard-lint  %s  langs=%s" % (a.corpus, ",".join(langs)))
        print("-" * 74)
    if corpus is not None and not a.quiet:
        counts = corpus.counts()
        bycat = {}
        bylang = {}
        for p in corpus.phrases:
            bycat[p.category] = bycat.get(p.category, 0) + 1
            bylang[p.lang] = bylang.get(p.lang, 0) + 1
        print("  phrases    %d" % len(corpus.phrases))
        print("  tiers      %s" % " ".join("%s=%d" % (k, counts[k])
                                           for k in sorted(counts)))
        print("  languages  %s" % " ".join("%s=%d" % (k, bylang[k])
                                           for k in sorted(bylang)))
        print("  categories %s" % " ".join("%s=%d" % (k, bycat[k])
                                           for k in sorted(bycat)))
        demote = [p for p in corpus.phrases
                  if "DEMOTE-CANDIDATE" in (p.notes or "").upper()]
        if demote:
            print()
            print("  %d DEMOTE-CANDIDATE row(s) -- watch these in shadow mode:"
                  % len(demote))
            for p in demote:
                print("    line %-4d %-8s %r" % (p.row, p.category, p.text))
        print()

    for f in sorted(findings, key=lambda x: (x.level != "ERROR", x.row)):
        print("  %-5s line %-4d %s" % (f.level, f.row, f.message))

    if not a.quiet:
        print()
        print("-" * 74)
        print("  %d error(s), %d warning(s)" % (len(errors), len(warns)))
        print()
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
