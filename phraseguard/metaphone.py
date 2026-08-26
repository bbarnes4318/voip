#!/usr/bin/env python3
"""Double Metaphone, for the brand nouns in the PhraseGuard corpus.

WHY THIS IS HERE AND NOT A PIP INSTALL
--------------------------------------
Everything in phraseguard/ is stdlib-only by design. The SBC terminates
customer traffic and the deploy is scp, not pip: a dependency added here is a
dependency someone has to install by hand on a border element, and a broken
one is a daemon that will not start. The only optional import in the whole
component is Vosk (asr.py), and that one falls back to a null recogniser
rather than failing.

WHAT IT IS FOR
--------------
8 kHz mu-law telephony audio with heavily accented speech runs 25-40% WER, and
brand names are the worst case in that distribution: they are out-of-vocabulary
for any general model, so the recogniser emits whatever English words sound
closest. "AnyDesk" comes back as "any disk", "any disc", "anti desk", "andy
desk". Levenshtein alone does not reliably close that gap -- "disc" and "desk"
are two edits apart on a four-letter word, which is a wide budget to hand a
matcher -- but they share a phonetic code exactly.

So brand-anchored corpus entries are matched on the Double Metaphone code of
the candidate span with whitespace removed, which makes "anydesk", "any desk",
"anydisk" and "any disc" one entry instead of four:

    anydesk   -> ANTSK          any desk  -> AN + TSK  -> ANTSK
    anydisk   -> ANTSK          any disc  -> AN + TSK  -> ANTSK

SCOPE
-----
This is the Lawrence Philips Double Metaphone as published, including the
Slavo-Germanic and Romance-language branches. Those branches are not exercised
by the current corpus -- it is Latin-script product names and American English
-- but they are cheap to carry and the alternative is a subset that silently
does the wrong thing the first time somebody adds a phrase it was not sized
for. The corpus is a data file that operators edit; the code under it should
not have undocumented edges.

Self-test: python3 metaphone.py
"""

_VOWELS = frozenset("AEIOUY")


def double_metaphone(word):
    """Return (primary, secondary) phonetic codes for a word.

    The secondary code carries the alternate pronunciation where the algorithm
    knows of one (e.g. "SCH" as SK or X). Callers should treat a match on
    EITHER code as a phonetic match -- see matcher.phonetic_equal.
    """
    word = "".join(c for c in word.upper() if "A" <= c <= "Z")
    if not word:
        return ("", "")

    length = len(word)
    last = length - 1
    primary = []
    secondary = []
    pos = 0

    # Cheap accessors. `at` never raises: reading past the end of the word is
    # the normal case in a lookahead-heavy algorithm, and returning "" for it
    # removes a bounds check from every single rule below.
    def at(i, j=None):
        if i < 0:
            return ""
        return word[i:(i + 1) if j is None else j]

    def string_at(start, slen, cands):
        if start < 0:
            return False
        return word[start:start + slen] in cands

    def add(p, s=None):
        primary.append(p)
        secondary.append(p if s is None else s)

    # "Slavo-Germanic" in Philips' sense: a spelling that signals the word did
    # not arrive through French or Spanish, which changes how J, G and CH are
    # pronounced.
    slavo = ("W" in word or "K" in word
             or "CZ" in word or "WITZ" in word)

    # Silent first letters. GN-, KN-, PN-, WR-, PS- all begin at index 1.
    if string_at(0, 2, ("GN", "KN", "PN", "WR", "PS")):
        pos = 1
    # Initial X is Spanish-derived and pronounced S ("Xavier").
    if at(0) == "X":
        add("S")
        pos = 1

    while pos < length:
        ch = word[pos]

        # --- vowels: only the first letter of the word codes at all --------
        if ch in _VOWELS:
            if pos == 0:
                add("A")
            pos += 1
            continue

        if ch == "B":
            add("P")
            pos += 2 if at(pos + 1) == "B" else 1

        elif ch == "C":
            # -ACH- as in "Bach", but not -ACHE- as in "backache", and not the
            # Romance -ACHER-/-ACHIN- which is CH.
            if (pos > 1 and at(pos - 2) not in _VOWELS
                    and string_at(pos - 1, 3, ("ACH",))
                    and at(pos + 2) != "I"
                    and (at(pos + 2) != "E"
                         or string_at(pos - 2, 6, ("BACHER", "MACHER")))):
                add("K")
                pos += 2
            elif pos == 0 and string_at(pos, 6, ("CAESAR",)):
                add("S")
                pos += 2
            elif string_at(pos, 4, ("CHIA",)):          # "chianti"
                add("K")
                pos += 2
            elif string_at(pos, 2, ("CH",)):
                if pos > 0 and string_at(pos, 4, ("CHAE",)):
                    add("K", "X")                        # "michael"
                    pos += 2
                elif (pos == 0
                      and (string_at(pos + 1, 5, ("HARAC", "HARIS"))
                           or string_at(pos + 1, 3, ("HOR", "HYM", "HIA", "HEM")))
                      and not string_at(0, 5, ("CHORE",))):
                    add("K")                             # Greek roots
                    pos += 2
                elif (string_at(0, 4, ("VAN ", "VON "))
                      or string_at(0, 3, ("SCH",))
                      or string_at(pos - 2, 6, ("ORCHES", "ARCHIT", "ORCHID"))
                      or at(pos + 2) in ("T", "S")
                      or ((at(pos - 1) in ("A", "O", "U", "E") or pos == 0)
                          and at(pos + 2) in ("L", "R", "N", "M", "B", "H",
                                              "F", "V", "W", " ", ""))):
                    add("K")                             # Germanic / Greek
                    pos += 2
                else:
                    # Philips: Mc- names take a hard K as the PRIMARY code
                    # ("McHugh"); everything else here is X with K as the
                    # alternate, so phonetic_equal can still pair a hard-CH
                    # reading with a soft one. Both arms were previously
                    # inverted, which gave MCHUGH ('MX','MK') instead of
                    # ('MK','MK') and stripped the K alternate from every
                    # other word taking this branch.
                    if string_at(0, 2, ("MC",)):
                        add("K")
                    else:
                        add("X", "K")
                    pos += 2
            elif string_at(pos, 2, ("CZ",)) and not string_at(pos - 2, 4, ("WICZ",)):
                add("S", "X")                            # "czerny"
                pos += 2
            elif string_at(pos + 1, 3, ("CIA",)):
                add("X")                                 # "focaccia"
                pos += 3
            elif string_at(pos, 2, ("CC",)) and not (pos == 1 and at(0) == "M"):
                # -CC- before I/E/H is "X" ("bellocchio") unless it is the
                # -CCE-/-CCI- that says KS ("accident", "success").
                if (string_at(pos + 2, 1, ("I", "E", "H"))
                        and not string_at(pos + 2, 2, ("HU",))):
                    if ((pos == 1 and at(pos - 1) == "A")
                            or string_at(pos - 1, 5, ("UCCEE", "UCCES"))):
                        add("KS")
                    else:
                        add("X")
                    pos += 3
                else:
                    add("K")
                    pos += 2
            elif string_at(pos, 2, ("CK", "CG", "CQ")):
                add("K")
                pos += 2
            elif string_at(pos, 2, ("CI", "CE", "CY")):
                if string_at(pos, 3, ("CIO", "CIE", "CIA")):
                    add("S", "X")
                else:
                    add("S")
                pos += 2
            else:
                add("K")
                # " C", " Q", " G" -- a following consonant that is really
                # part of the same sound.
                if string_at(pos + 1, 2, (" C", " Q", " G")):
                    pos += 3
                elif (string_at(pos + 1, 1, ("C", "K", "Q"))
                      and not string_at(pos + 1, 2, ("CE", "CI"))):
                    pos += 2
                else:
                    pos += 1

        elif ch == "D":
            if string_at(pos, 2, ("DG",)):
                if string_at(pos + 2, 1, ("I", "E", "Y")):
                    add("J")                             # "edge"
                    pos += 3
                else:
                    add("TK")                            # "edgar"
                    pos += 2
            elif string_at(pos, 2, ("DT", "DD")):
                add("T")
                pos += 2
            else:
                add("T")
                pos += 1

        elif ch == "F":
            add("F")
            pos += 2 if at(pos + 1) == "F" else 1

        elif ch == "G":
            if at(pos + 1) == "H":
                if pos > 0 and at(pos - 1) not in _VOWELS:
                    add("K")
                    pos += 2
                elif pos == 0:
                    # 'ghislane', 'ghiradelli'. Only position 0 short-circuits
                    # here; positions 1 and 2 fall THROUGH to Parker's rule
                    # below. Adding "K" for them instead mis-codes the whole
                    # English -IGHT family: 'night' became NKT rather than NT,
                    # which collides exactly with 'naked'.
                    add("J" if at(pos + 2) == "I" else "K")
                    pos += 2
                elif ((pos > 1 and string_at(pos - 2, 1, ("B", "H", "D")))
                      or (pos > 2 and string_at(pos - 3, 1, ("B", "H", "D")))
                      or (pos > 3 and string_at(pos - 4, 1, ("B", "H")))):
                    pos += 2                             # silent: "hugh"
                else:
                    if (pos > 2 and at(pos - 1) == "U"
                            and string_at(pos - 3, 1, ("C", "G", "L", "R", "T"))):
                        add("F")                         # "laugh", "rough"
                    elif pos > 0 and at(pos - 1) != "I":
                        add("K")
                    pos += 2
            elif at(pos + 1) == "N":
                if pos == 1 and at(0) in _VOWELS and not slavo:
                    add("KN", "N")
                elif not string_at(pos + 2, 2, ("EY",)) and at(pos + 1) != "Y" and not slavo:
                    add("N", "KN")
                else:
                    add("KN")
                pos += 2
            elif string_at(pos + 1, 2, ("LI",)) and not slavo:
                add("KL", "L")                           # "tagliaro"
                pos += 2
            elif pos == 0 and (at(pos + 1) == "Y"
                               or string_at(pos + 1, 2, ("ES", "EP", "EB", "EL",
                                                         "EY", "IB", "IL", "IN",
                                                         "IE", "EI", "ER"))):
                add("K", "J")
                pos += 2
            elif ((string_at(pos + 1, 2, ("ER",)) or at(pos + 1) == "Y")
                  and not string_at(0, 6, ("DANGER", "RANGER", "MANGER"))
                  and not string_at(pos - 1, 1, ("E", "I"))
                  and not string_at(pos - 1, 3, ("RGY", "OGY"))):
                add("K", "J")
                pos += 2
            elif (string_at(pos + 1, 1, ("E", "I", "Y"))
                  or string_at(pos - 1, 4, ("AGGI", "OGGI"))):
                if (string_at(0, 4, ("VAN ", "VON ")) or string_at(0, 3, ("SCH",))
                        or string_at(pos + 1, 2, ("ET",))):
                    add("K")
                elif string_at(pos + 1, 4, ("IER ",)):
                    add("J")
                else:
                    add("J", "K")
                pos += 2
            else:
                add("K")
                pos += 2 if at(pos + 1) == "G" else 1

        elif ch == "H":
            # Only pronounced between two vowels, or word-initially.
            if (pos == 0 or at(pos - 1) in _VOWELS) and at(pos + 1) in _VOWELS:
                add("H")
                pos += 2
            else:
                pos += 1

        elif ch == "J":
            if string_at(pos, 4, ("JOSE",)) or string_at(0, 4, ("SAN ",)):
                if ((pos == 0 and at(pos + 4) == " ") or string_at(0, 4, ("SAN ",))):
                    add("H")                             # Spanish "Jose"
                else:
                    add("J", "H")
                pos += 1
            elif pos == 0 and not string_at(pos, 4, ("JOSE",)):
                add("J", "A")
            else:
                if (at(pos - 1) in _VOWELS and not slavo
                        and at(pos + 1) in ("A", "O")):
                    add("J", "H")
                elif pos == last:
                    add("J", "")
                elif (at(pos + 1) not in ("L", "T", "K", "S", "N", "M", "B", "Z")
                      and at(pos - 1) not in ("S", "K", "L")):
                    add("J")
                pos += 1
                continue
            pos += 2 if at(pos + 1) == "J" else 1

        elif ch == "K":
            add("K")
            pos += 2 if at(pos + 1) == "K" else 1

        elif ch == "L":
            if at(pos + 1) == "L":
                # Spanish -LLO/-LLA is silent in the alternate reading.
                if ((pos == length - 3
                     and string_at(pos - 1, 4, ("ILLO", "ILLA", "ALLE")))
                        or ((string_at(last - 1, 2, ("AS", "OS"))
                             or string_at(last, 1, ("A", "O")))
                            and string_at(pos - 1, 4, ("ALLE",)))):
                    add("L", "")
                    pos += 2
                    continue
                pos += 2
            else:
                pos += 1
            add("L")

        elif ch == "M":
            # -UMB word-final or before -ER is a silent B ("thumb", "dumber").
            if ((string_at(pos - 1, 3, ("UMB",))
                 and (pos + 1 == last or string_at(pos + 2, 2, ("ER",))))
                    or at(pos + 1) == "M"):
                pos += 2
            else:
                pos += 1
            add("M")

        elif ch == "N":
            add("N")
            pos += 2 if at(pos + 1) == "N" else 1

        elif ch == "P":
            if at(pos + 1) == "H":
                add("F")
                pos += 2
            else:
                add("P")
                pos += 2 if at(pos + 1) in ("P", "B") else 1

        elif ch == "Q":
            add("K")
            pos += 2 if at(pos + 1) == "Q" else 1

        elif ch == "R":
            # Word-final -IER is French and silent ("rogier"), unless the word
            # looks Slavo-Germanic or ends -MEIER/-MAIER.
            if (pos == last and not slavo and string_at(pos - 2, 2, ("IE",))
                    and not string_at(pos - 4, 2, ("ME", "MA"))):
                add("", "R")
            else:
                add("R")
            pos += 2 if at(pos + 1) == "R" else 1

        elif ch == "S":
            if string_at(pos - 1, 3, ("ISL", "YSL")):
                pos += 1                                 # silent: "island"
            elif pos == 0 and string_at(pos, 5, ("SUGAR",)):
                add("X", "S")
                pos += 1
            elif string_at(pos, 2, ("SH",)):
                if string_at(pos + 1, 4, ("HEIM", "HOEK", "HOLM", "HOLZ")):
                    add("S")                             # Germanic
                else:
                    add("X")
                pos += 2
            elif string_at(pos, 3, ("SIO", "SIA")) or string_at(pos, 4, ("SIAN",)):
                add("S" if slavo else "S", "X" if not slavo else "S")
                pos += 3
            elif ((pos == 0 and at(pos + 1) in ("M", "N", "L", "W"))
                  or at(pos + 1) == "Z"):
                add("S", "X")
                pos += 2 if at(pos + 1) == "Z" else 1
            elif string_at(pos, 2, ("SC",)):
                if at(pos + 2) == "H":
                    if string_at(pos + 3, 2, ("OO", "ER", "EN", "UY", "ED", "EM")):
                        if string_at(pos + 3, 2, ("ER", "EN")):
                            add("X", "SK")
                        else:
                            add("SK")
                    elif pos == 0 and at(3) not in _VOWELS and at(3) != "W":
                        add("X", "S")
                    else:
                        add("X")
                elif at(pos + 2) in ("I", "E", "Y"):
                    add("S")
                else:
                    add("SK")
                pos += 3
            else:
                if pos == last and string_at(pos - 2, 2, ("AI", "OI")):
                    add("", "S")                         # French final S
                else:
                    add("S")
                pos += 2 if at(pos + 1) in ("S", "Z") else 1

        elif ch == "T":
            if string_at(pos, 4, ("TION",)):
                add("X")
                pos += 3
            elif string_at(pos, 3, ("TIA", "TCH")):
                add("X")
                pos += 3
            elif string_at(pos, 2, ("TH",)) or string_at(pos, 3, ("TTH",)):
                # "Thomas"/"Thames" are T; everything else is a real TH.
                if (string_at(pos + 2, 2, ("OM", "AM"))
                        or string_at(0, 4, ("VAN ", "VON "))
                        or string_at(0, 3, ("SCH",))):
                    add("T")
                else:
                    add("0", "T")
                pos += 2
            else:
                add("T")
                pos += 2 if at(pos + 1) in ("T", "D") else 1

        elif ch == "V":
            add("F")
            pos += 2 if at(pos + 1) == "V" else 1

        elif ch == "W":
            if string_at(pos, 2, ("WR",)):
                add("R")
                pos += 2
            elif pos == 0 and (at(pos + 1) in _VOWELS or string_at(pos, 2, ("WH",))):
                # Initial W before a vowel is a real W; WH- is also W.
                if at(pos + 1) in _VOWELS:
                    add("A", "F")
                else:
                    add("A")
                pos += 1
            elif ((pos == last and at(pos - 1) in _VOWELS)
                  or string_at(pos - 1, 5, ("EWSKI", "EWSKY", "OWSKI", "OWSKY"))
                  or string_at(0, 3, ("SCH",))):
                add("", "F")                             # Polish -EWSKI
                pos += 1
            elif string_at(pos, 4, ("WICZ", "WITZ")):
                add("TS", "FX")
                pos += 4
            else:
                pos += 1

        elif ch == "X":
            if not (pos == last and (string_at(pos - 3, 3, ("IAU", "EAU"))
                                     or string_at(pos - 2, 2, ("AU", "OU")))):
                add("KS")
            pos += 2 if at(pos + 1) in ("C", "X") else 1

        elif ch == "Z":
            if at(pos + 1) == "H":
                add("J")                                 # Chinese pinyin
                pos += 2
            else:
                if (string_at(pos + 1, 2, ("ZO", "ZI", "ZA"))
                        or (slavo and pos > 0 and at(pos - 1) != "T")):
                    add("S", "TS")
                else:
                    add("S")
                pos += 2 if at(pos + 1) == "Z" else 1

        else:
            pos += 1

    return ("".join(primary), "".join(secondary))


def phonetic_key(text):
    """Primary Double Metaphone code of `text` with all whitespace removed.

    Whitespace removal is the point: it is what collapses "anydesk" and
    "any desk" onto one code. Callers that want to compare a two-token span
    against a one-token brand entry get that for free.
    """
    return double_metaphone("".join(text.split()))[0]


def phonetic_equal(a, b):
    """True if two strings share EITHER Double Metaphone code.

    Either, not both: the secondary code exists to carry a genuine alternate
    pronunciation, and requiring agreement on both would throw away the cases
    it was added for.
    """
    a1, a2 = double_metaphone("".join(a.split()))
    b1, b2 = double_metaphone("".join(b.split()))
    if not a1 or not b1:
        return False
    return a1 == b1 or a1 == b2 or a2 == b1 or (a2 and a2 == b2)


# ---------------------------------------------------------------------------
# Self-test. Not a unit-test framework -- this file is deployed to a border
# element and `python3 metaphone.py` has to be a complete answer to "is this
# working" with nothing installed.
#
# The cases are the ones that matter for the corpus: every brand noun the
# recogniser is expected to mangle, in the forms it is expected to mangle them
# into. They come from the brief's own list, not from the algorithm's paper.
# ---------------------------------------------------------------------------
_SELFTEST = [
    # (a, b, should_match)
    ("anydesk", "any desk", True),
    ("anydesk", "anydisk", True),
    ("anydesk", "any disc", True),
    ("anydesk", "any disk", True),
    ("teamviewer", "team viewer", True),
    ("ultraviewer", "ultra viewer", True),
    ("logmein", "log me in", True),
    ("moneygram", "money gram", True),
    ("moneypak", "money pack", True),
    ("splashtop", "splash top", True),
    ("rustdesk", "rust desk", True),
    ("coinstar", "coin star", True),
    ("screenconnect", "screen connect", True),
    ("gotoassist", "go to assist", True),
    ("western union", "westernunion", True),
    # Negative controls. A phonetic matcher that says yes to everything is
    # worse than no phonetic matcher, because it does it at Tier A.
    ("anydesk", "any death", False),
    ("teamviewer", "team review", False),
    ("bitcoin", "big coin", False),
    ("coinstar", "corn star", False),
    ("splashtop", "splash shop", False),
]

# ---------------------------------------------------------------------------
# KNOWN COLLISIONS.
#
# Double Metaphone throws away the distinctions these pairs depend on, by
# design -- D and T collapse to T, and the codes carry no vowels. These are
# asserted rather than fixed, because the day one of them starts firing on
# real traffic the first question will be "did the phonetic matcher do this",
# and a list that says "yes, and here is the one that does it" answers faster
# than re-deriving the algorithm.
#
# Neither is currently reachable at Tier A:
#
#   moneygram / monogram  -- moneygram IS anchor=brand and IS phonetically
#       matched, so a prospect saying "monogram" would hit it. On a trunk
#       carrying insurance and lead-gen to CONUS-48 consumers that is not a
#       word that comes up, and the alternative (dropping moneygram to
#       anchor=pair) loses the accent robustness that put it in brand in the
#       first place. Accepted, and listed in README.md under false positives
#       to watch in shadow mode.
#
#   gift card / gift cart -- unreachable: "gift card" is anchor=pair, and pair
#       entries are matched by edit distance on the tokens, never phonetically.
#       Recorded here so that nobody "fixes" it by promoting the entry to
#       brand without realising that is what the promotion would cost.
# ---------------------------------------------------------------------------
_KNOWN_COLLISIONS = [
    ("moneygram", "monogram", "brand entry; accepted, watch in shadow mode"),
    ("gift card", "gift cart", "unreachable: gift card is anchor=pair"),
]


def _selftest():
    bad = 0
    print("double_metaphone self-test")
    print("-" * 72)
    for a, b, want in _SELFTEST:
        got = phonetic_equal(a, b)
        ok = got == want
        if not ok:
            bad += 1
        print("  %-4s %-16s %-16s  %s / %s"
              % ("ok" if ok else "FAIL", a, b,
                 phonetic_key(a), phonetic_key(b)))
    print("-" * 72)
    print("  known collisions (asserted, not defects):")
    for a, b, why in _KNOWN_COLLISIONS:
        if not phonetic_equal(a, b):
            bad += 1
            print("    FAIL %-14s %-14s no longer collides -- update the list" % (a, b))
        else:
            print("    ok   %-14s %-14s %s" % (a, b, why))
    print("-" * 72)
    print("  %d case(s), %d failure(s)"
          % (len(_SELFTEST) + len(_KNOWN_COLLISIONS), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    import sys
    sys.exit(_selftest())
