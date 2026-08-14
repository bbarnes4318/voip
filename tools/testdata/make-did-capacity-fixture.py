#!/usr/bin/env python3
"""
make-did-capacity-fixture.py — synthetic CDR for analyze-did-capacity.py.

    python3 tools/testdata/make-did-capacity-fixture.py OUTDIR

Writes OUTDIR/sbc-fixture.csv and OUTDIR/dids-fixture.csv. Deliberately covers
the four cases that break a naive capacity model:

  212  pool of 2, 600 calls/day   -> exhausts mid-morning and spills
  310  pool of 40, 200 calls/day  -> never exhausts; grossly over-provisioned
  415  NO pool at all, 300/day    -> 100% overflow, structurally not a spill
  510  NO pool, 5000 on day 2     -> drives OVERFLOW itself to exhaustion

Plus transfer legs (no DID drawn) and pre-selection rejects (NOT_NANP,
CONCURRENCY_CAP), both of which must be excluded from pool demand. Counting
either would inflate the purchase plan.

Numbers are 555-01XX fiction, matching dids.csv.example.
"""
import csv
import os
import sys

DAY1, DAY2 = "2026-08-12", "2026-08-13"


def row(ts, dest, npa, reason, did, reject="", disp="ANSWERED", count=""):
    return [ts, ts if disp == "ANSWERED" else "", ts,
            "198.51.100.21", "pkclient1", "12125550100", dest,
            "30" if disp == "ANSWERED" else "0",
            "25" if disp == "ANSWERED" else "0",
            disp, "16" if disp == "ANSWERED" else "34", "fractel1",
            "call-%s-%s" % (npa, ts.replace(" ", "")), reject,
            "1.%d" % (abs(hash(ts + dest + reason)) % 10 ** 8),
            did, reason, npa, str(count), ""]


def spread(day, n, start_h, end_h):
    """n timestamps spread evenly across [start_h, end_h), in order."""
    span = max(1, end_h - start_h)
    out = []
    for i in range(n):
        # Fraction of the window this call falls at, converted to h:m:s. Order
        # is what matters: the tool reads the FIRST spill hour, so the calls
        # that exhaust a pool have to come before the ones that spill.
        mins = (i * span * 60) // max(1, n)
        h = min(23, start_h + mins // 60)
        out.append("%s %02d:%02d:%02d" % (day, h, mins % 60, i % 60))
    return out


def emit(w, day, npa, n_match, n_overflow, n_refused, start_h=8, end_h=20):
    """One NPA's day: pool calls first, then spill, then refusals."""
    ts = spread(day, n_match + n_overflow + n_refused, start_h, end_h)
    i = 0
    for k in range(n_match):
        w.writerow(row(ts[i], "1%s5550%03d" % (npa, k % 999), npa,
                       "npa_match", "1%s5550101" % npa, count=(k % 200) + 1))
        i += 1
    for k in range(n_overflow):
        w.writerow(row(ts[i], "1%s5550%03d" % (npa, k % 999), npa,
                       "overflow", "18885550%03d" % (k % 200), count=(k % 200) + 1))
        i += 1
    for k in range(n_refused):
        w.writerow(row(ts[i], "1%s5550%03d" % (npa, k % 999), npa,
                       "none", "", reject="NO_DID_AVAILABLE", disp="CONGESTION"))
        i += 1


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(outdir, exist_ok=True)

    cdr = os.path.join(outdir, "sbc-fixture.csv")
    with open(cdr, "w", newline="") as fh:
        w = csv.writer(fh, quoting=csv.QUOTE_ALL)

        # --- day 1: overflow copes -----------------------------------------
        # 212 has 2 DIDs = 400/day of capacity against 600 of demand, and its
        # traffic is concentrated 06:00-12:00. Capacity is gone two thirds of
        # the way through that window, so it exhausts around 10:00.
        emit(w, DAY1, "212", n_match=400, n_overflow=200, n_refused=0,
             start_h=6, end_h=12)
        # 310 has 40 DIDs = 8000/day of capacity against 200 of demand.
        emit(w, DAY1, "310", n_match=200, n_overflow=0, n_refused=0)
        # 415 has no pool. Every call is overflow from the first one; this is
        # structural, not exhaustion, and the tool must not call it a spill.
        emit(w, DAY1, "415", n_match=0, n_overflow=300, n_refused=0)

        # --- day 2: overflow itself exhausts -------------------------------
        emit(w, DAY2, "212", n_match=400, n_overflow=200, n_refused=0,
             start_h=6, end_h=12)
        emit(w, DAY2, "310", n_match=200, n_overflow=0, n_refused=0)
        emit(w, DAY2, "415", n_match=0, n_overflow=300, n_refused=0)
        # 510 has no pool and a huge day. Overflow is 20 DIDs = 4000/day; with
        # 200+300+5000 of demand against it, 1500 calls are refused outright.
        emit(w, DAY2, "510", n_match=0, n_overflow=3500, n_refused=1500)

        # --- rows that must NOT count as pool demand -----------------------
        for k in range(50):
            w.writerow(row("%s 09:%02d:00" % (DAY1, k % 60), "18005550100",
                           "800", "transfer_leg_tollfree", ""))
        for k in range(30):
            w.writerow(row("%s 09:%02d:30" % (DAY1, k % 60), "447700900000",
                           "", "", "", reject="NOT_NANP", disp="CONGESTION"))
        for k in range(20):
            w.writerow(row("%s 10:%02d:30" % (DAY1, k % 60), "12125550999",
                           "212", "", "", reject="CONCURRENCY_CAP",
                           disp="CONGESTION"))

    dids = os.path.join(outdir, "dids-fixture.csv")
    with open(dids, "w", newline="") as fh:
        fh.write("# synthetic pool for analyze-did-capacity.py tests\n")
        fh.write("npa,did\n")
        for k in range(2):
            fh.write("212,1212555010%d\n" % k)
        for k in range(40):
            fh.write("310,13105550%03d\n" % k)
        # 415 and 510 deliberately absent.
        for k in range(20):
            fh.write("OVERFLOW,18885550%03d\n" % k)

    sys.stderr.write("wrote %s and %s\n" % (cdr, dids))


if __name__ == "__main__":
    main()
