#!/usr/bin/env python3
"""
analyze-did-capacity.py -- size the DID pool against observed demand.

    python3 tools/analyze-did-capacity.py --cdr /var/log/asterisk/cdr-custom/sbc.csv

Read-only. Answers one question: how many numbers does this traffic actually
need, and where is the current pool in the wrong place?

NO_DID_AVAILABLE is a refused call -- every DID in the destination NPA's pool
AND every DID in overflow was at its daily cap. It is a connect-rate loss that
no amount of route diversity can recover, because the call never reaches a
carrier at all.

    --cdr PATH         CDR file. Repeatable. .gz is read transparently.
                       Default /var/log/asterisk/cdr-custom/sbc.csv
    --dids PATH        the DID pool (default dids.csv). Supplies pool sizes;
                       without it, per-NPA pool size and surplus are unknown.
    --window DAYS      only consider the last N days present in the data.
    --cap N            the cap currently in force (default 200). Used to judge
                       today's provisioning, not to model.
    --caps LIST        caps to model (default 200,150,100,75).
    --did-cost RATE    monthly cost per DID (default 0.50).
    --overflow-min N   floor on the overflow pool (default 20, matches
                       OVERFLOW_MIN in render.sh).
    --headroom PCT     size pools this far above observed peak (default 0).
    --out PATH         write the purchase plan CSV here. '-' for stdout.
    --quiet            suppress the human-readable report; CSV only.

WHY LOWER CAPS ARE MODELLED AND HIGHER ONES ARE NOT
    200 calls/day/DID is already aggressive for analytics reputation. Raising
    it trades a reputation problem for a capacity one and the reputation
    problem is the expensive one. So this tool models 200 and BELOW, and the
    output it exists to produce is a number of DIDs to buy.

WHAT THIS READS
    CDR columns, 1-indexed, per asterisk/cdr_custom.conf.tpl:
        1  timestamp_start     14 reject_reason
        7  destination         16 selected_did
       10  disposition         17 did_selection_reason
                               18 destination_npa
                               19 did_daily_count_at_selection

    destination_npa is set BEFORE DID selection runs, so it is populated on
    refused rows too. That is what makes demand attributable to an NPA even
    when no DID was ever drawn for it.

TWO DIFFERENT PROBLEMS, REPORTED SEPARATELY
    An NPA with 2 DIDs and 400 calls is under-provisioned. An NPA with 40 DIDs
    and 200 calls is mis-allocated: those numbers are paid for monthly and are
    doing nothing. Both are failures of the same pool and they need opposite
    fixes, so the report never nets them off against each other.
"""

import argparse
import csv
import gzip
import io
import math
import os
import sys
from collections import defaultdict

# CDR column indices, 0-based.
C_START = 0
C_DEST = 6
C_DISPOSITION = 9
C_REJECT = 13
C_DID = 15
C_REASON = 16
C_NPA = 17
C_DIDCOUNT = 18
CDR_MIN_COLS = 19

# did_selection_reason values that mean a DID was drawn from a pool and a
# daily allowance was consumed.
CONSUMING = ("npa_match", "overflow")
# Transfer legs pass the customer's caller ID through untouched: no DID is
# drawn and no allowance is consumed, so they are not demand on the pool.
TRANSFER_PREFIX = "transfer_leg_"


def die(msg):
    sys.stderr.write("analyze-did-capacity.py: ERROR: %s\n" % msg)
    sys.exit(1)


def open_maybe_gz(path):
    if path.endswith(".gz"):
        return io.TextIOWrapper(gzip.open(path, "rb"), errors="replace")
    return open(path, "r", newline="", errors="replace")


def load_dids(path):
    """dids.csv -> {npa: set(dids)}. Parsed the way render.sh parses it."""
    pools = defaultdict(set)
    if not path or not os.path.exists(path):
        return None
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "," not in line:
                continue
            npa, rest = line.split(",", 1)
            did = rest.split(",", 1)[0]
            npa = npa.strip().upper()
            did = "".join(c for c in did if c.isdigit())
            if npa == "NPA" or not did:
                continue
            if len(did) == 10:
                did = "1" + did
            pools[npa].add(did)
    return dict(pools)


def read_cdr(paths):
    """Yield CDR rows with at least CDR_MIN_COLS fields."""
    total = short = 0
    for p in paths:
        if not os.path.exists(p):
            die("CDR not found: %s" % p)
        with open_maybe_gz(p) as fh:
            for row in csv.reader(fh):
                total += 1
                if len(row) < CDR_MIN_COLS:
                    short += 1
                    continue
                yield row
    if total == 0:
        die("no CDR rows read")
    if short:
        sys.stderr.write(
            "  note: %d of %d row(s) had fewer than %d columns and were skipped\n"
            % (short, total, CDR_MIN_COLS))


def day_of(ts):
    return ts[:10]


def hour_of(ts):
    try:
        return int(ts[11:13])
    except (ValueError, IndexError):
        return None


def analyze(rows, window):
    """Bucket every DID-consuming call by NPA, day and hour."""
    st = {
        "days": set(),
        # demand[npa][day] = calls that reached DID selection
        "demand": defaultdict(lambda: defaultdict(int)),
        "npa_match": defaultdict(lambda: defaultdict(int)),
        "overflow": defaultdict(lambda: defaultdict(int)),
        "refused": defaultdict(lambda: defaultdict(int)),
        # first hour an NPA spilled to overflow / was refused, per day
        "spill_hour": defaultdict(dict),
        "refuse_hour": defaultdict(dict),
        "dids_seen": defaultdict(int),
        "rows": 0,
        "transfer": 0,
        "pre_reject": 0,
    }

    for r in rows:
        st["rows"] += 1
        ts = r[C_START]
        day = day_of(ts)
        st["days"].add(day)

        reason = r[C_REASON].strip()
        reject = r[C_REJECT].strip()
        npa = r[C_NPA].strip()
        did = r[C_DID].strip()

        if did:
            st["dids_seen"][did] += 1

        if reason.startswith(TRANSFER_PREFIX):
            st["transfer"] += 1
            continue

        refused = (reject == "NO_DID_AVAILABLE")
        if not refused and reason not in CONSUMING:
            # Refused before DID selection ever ran: NOT_NANP, BLOCKED_NPA,
            # CPS_LIMIT, CONCURRENCY_CAP, HIGH_COST_PREFIX, KILLSWITCH. Not
            # demand on the pool, and counting it would inflate the purchase.
            st["pre_reject"] += 1
            continue

        if not npa:
            npa = "(unknown)"

        st["demand"][npa][day] += 1
        h = hour_of(ts)

        if refused:
            st["refused"][npa][day] += 1
            if day not in st["refuse_hour"][npa] and h is not None:
                st["refuse_hour"][npa][day] = h
        elif reason == "overflow":
            st["overflow"][npa][day] += 1
            if day not in st["spill_hour"][npa] and h is not None:
                st["spill_hour"][npa][day] = h
        elif reason == "npa_match":
            st["npa_match"][npa][day] += 1

    if window:
        keep = set(sorted(st["days"])[-window:])
        st["days"] = keep
        for key in ("demand", "npa_match", "overflow", "refused"):
            for npa in list(st[key]):
                st[key][npa] = {d: v for d, v in st[key][npa].items() if d in keep}
                if not st[key][npa]:
                    del st[key][npa]
    return st


def peak(perday):
    return max(perday.values()) if perday else 0


def needed_dids(demand_peak, cap, headroom_pct):
    if demand_peak <= 0:
        return 0
    target = demand_peak * (1.0 + headroom_pct / 100.0)
    return int(math.ceil(target / float(cap)))


def build_rows(st, pools, caps, headroom):
    """One record per NPA, with need at each modelled cap."""
    out = []
    npas = set(st["demand"]) | set(pools or {})
    for npa in npas:
        if npa == "OVERFLOW":
            continue
        d = st["demand"].get(npa, {})
        pk = peak(d)
        pool = len(pools[npa]) if pools and npa in pools else 0
        rec = {
            "npa": npa,
            "pool_size": pool,
            "peak_daily_demand": pk,
            "total_demand": sum(d.values()),
            "npa_match": sum(st["npa_match"].get(npa, {}).values()),
            "overflow": sum(st["overflow"].get(npa, {}).values()),
            "refused": sum(st["refused"].get(npa, {}).values()),
            "spill_hours": st["spill_hour"].get(npa, {}),
            "refuse_hours": st["refuse_hour"].get(npa, {}),
            "has_pool": pool > 0,
        }
        served = rec["npa_match"] + rec["overflow"]
        rec["overflow_share"] = (rec["overflow"] / served) if served else 0.0
        for cap in caps:
            n = needed_dids(pk, cap, headroom)
            rec["need_%d" % cap] = n
            rec["buy_%d" % cap] = max(0, n - pool)
        out.append(rec)
    out.sort(key=lambda r: (-r["refused"], -r["peak_daily_demand"]))
    return out


def overflow_record(st, pools, caps, headroom):
    """Overflow's own demand: every call that fell to it, plus every refusal."""
    perday = defaultdict(int)
    for npa in st["overflow"]:
        for day, n in st["overflow"][npa].items():
            perday[day] += n
    for npa in st["refused"]:
        for day, n in st["refused"][npa].items():
            perday[day] += n
    pk = peak(perday)
    pool = len(pools["OVERFLOW"]) if pools and "OVERFLOW" in pools else 0
    rec = {"npa": "OVERFLOW", "pool_size": pool, "peak_daily_demand": pk,
           "total_demand": sum(perday.values()), "perday": dict(perday)}
    for cap in caps:
        n = needed_dids(pk, cap, headroom)
        rec["need_%d" % cap] = n
        rec["buy_%d" % cap] = max(0, n - pool)
    return rec


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def fmt_hours(hours):
    if not hours:
        return "-"
    vals = sorted(hours.values())
    if len(set(vals)) == 1:
        return "%02d:00" % vals[0]
    return "%02d-%02d:00" % (vals[0], vals[-1])


def report(st, pools, recs, ofrec, caps, cur_cap, cost, overflow_min, out=sys.stdout):
    days = sorted(st["days"])
    w = out.write
    w("\n=== DID capacity ===\n")
    w("  CDR rows            %d\n" % st["rows"])
    w("  days                %d  (%s .. %s)\n"
      % (len(days), days[0] if days else "-", days[-1] if days else "-"))
    w("  DID-consuming calls %d\n" % sum(r["total_demand"] for r in recs))
    w("  transfer legs       %d  (no DID drawn, no allowance consumed)\n" % st["transfer"])
    w("  refused before DID  %d  (not pool demand)\n" % st["pre_reject"])

    tot_ref = sum(r["refused"] for r in recs)
    tot_dem = sum(r["total_demand"] for r in recs)
    w("\n  NO_DID_AVAILABLE    %d  (%.1f%% of DID-consuming calls)\n"
      % (tot_ref, 100.0 * tot_ref / tot_dem if tot_dem else 0.0))

    # --- 1. per-NPA exhaustion ---------------------------------------------
    w("\n--- 1. per destination NPA (worst 25 by refusals) ---\n")
    w("  %-8s %6s %8s %8s %9s %8s %9s\n"
      % ("NPA", "pool", "demand", "peak/day", "overflow", "refused", "exhausted"))
    shown = 0
    for r in recs:
        if r["total_demand"] == 0 and r["pool_size"] == 0:
            continue
        if shown >= 25:
            break
        shown += 1
        # An NPA with no pool has nothing to exhaust: its very first call goes
        # to overflow. Reporting an hour there would read as a capacity event
        # and send the operator looking for a spike that does not exist.
        when = "no pool" if not r["has_pool"] else fmt_hours(
            r["spill_hours"] or r["refuse_hours"])
        w("  %-8s %6d %8d %8d %9d %8d %9s\n"
          % (r["npa"], r["pool_size"], r["total_demand"], r["peak_daily_demand"],
             r["overflow"], r["refused"], when))
    w("\n  'exhausted' is the first hour that NPA's own pool spilled to overflow.\n")
    w("  'no pool' means there was never a dedicated pool to exhaust -- every\n")
    w("  call went to overflow from the first one. Different problem, same symptom.\n")

    # --- 2. overflow dependency --------------------------------------------
    w("\n--- 2. overflow dependency ---\n")
    for day in days:
        nm = sum(st["npa_match"][n].get(day, 0) for n in st["npa_match"])
        ov = sum(st["overflow"][n].get(day, 0) for n in st["overflow"])
        rf = sum(st["refused"][n].get(day, 0) for n in st["refused"])
        tot = nm + ov + rf
        if not tot:
            continue
        w("  %s  npa_match %6d (%5.1f%%)   overflow %6d (%5.1f%%)   refused %6d (%5.1f%%)\n"
          % (day, nm, 100.0 * nm / tot, ov, 100.0 * ov / tot, rf, 100.0 * rf / tot))

    # An NPA with no pool of its own is not "spilling" -- it never had anywhere
    # else to go. Structural, and fixed by buying numbers in it. An NPA WITH a
    # pool that still spills is a sizing failure. Different fixes.
    nopool = [r for r in recs if not r["has_pool"] and r["total_demand"] > 0]
    # ANY spill from a pooled NPA means that pool ran out -- a pool that is big
    # enough never reaches overflow at all. Reporting only the pools where
    # overflow carries the MAJORITY understates this badly: a pool can exhaust
    # every single day and still show a minority share, because the calls that
    # matched before it ran out are counted on the other side.
    any_spill = [r for r in recs if r["has_pool"] and r["overflow"] > 0]
    majority = [r for r in recs if r["has_pool"] and r["overflow_share"] > 0.5]
    pooled = [r for r in recs if r["has_pool"]]

    w("\n  NPAs with NO dedicated pool (structural: every call goes to overflow)\n")
    if nopool:
        nopool.sort(key=lambda r: -r["total_demand"])
        w("    %d NPA(s), %d call(s), %d refusal(s). Worst: %s\n"
          % (len(nopool), sum(r["total_demand"] for r in nopool),
             sum(r["refused"] for r in nopool),
             ", ".join("%s (%d)" % (r["npa"], r["total_demand"]) for r in nopool[:8])))
    else:
        w("    none\n")

    w("  NPAs WITH a pool that exhausted at all (sizing failure)\n")
    if any_spill:
        any_spill.sort(key=lambda r: -r["overflow"])
        w("    %d of %d pooled NPA(s). Worst by spilled calls: %s\n"
          % (len(any_spill), len(pooled),
             ", ".join("%s (%d on %d DID(s))" % (r["npa"], r["overflow"], r["pool_size"])
                       for r in any_spill[:8])))
        w("    of those, %d carry the MAJORITY of their traffic on overflow\n"
          % len(majority))
    else:
        w("    none of %d pooled NPA(s) ever reached overflow\n" % len(pooled))

    # --- misallocation ------------------------------------------------------
    w("\n--- 3. allocation: under vs over ---\n")
    under = [r for r in recs if r["buy_%d" % cur_cap] > 0]
    over = [r for r in recs
            if r["pool_size"] > r["need_%d" % cur_cap] and r["pool_size"] > 0]
    # Sorted by shortfall, NOT by refusals. An NPA whose spill was absorbed by
    # overflow produces no refusals at all and would otherwise never surface,
    # even when it is the most badly under-provisioned pool on the box.
    under.sort(key=lambda r: -r["buy_%d" % cur_cap])
    w("  UNDER-provisioned at cap %d: %d NPA(s), %d DID(s) short\n"
      % (cur_cap, len(under), sum(r["buy_%d" % cur_cap] for r in under)))
    w("    (worst first by shortfall; an existing pool that is too small can\n")
    w("     show zero refusals because overflow absorbed the spill)\n")
    for r in under[:10]:
        w("    %-6s pool %3d, peak %5d/day, needs %3d  (+%d)\n"
          % (r["npa"], r["pool_size"], r["peak_daily_demand"],
             r["need_%d" % cur_cap], r["buy_%d" % cur_cap]))
    surplus = sum(r["pool_size"] - r["need_%d" % cur_cap] for r in over)
    w("\n  OVER-provisioned at cap %d: %d NPA(s), %d DID(s) surplus ($%.2f/mo idle)\n"
      % (cur_cap, len(over), surplus, surplus * cost))
    over.sort(key=lambda r: -(r["pool_size"] - r["need_%d" % cur_cap]))
    for r in over[:10]:
        w("    %-6s pool %3d, peak %5d/day, needs %3d  (-%d)\n"
          % (r["npa"], r["pool_size"], r["peak_daily_demand"],
             r["need_%d" % cur_cap], r["pool_size"] - r["need_%d" % cur_cap]))
    idle = 0
    if pools:
        allocated = set()
        for n, s in pools.items():
            allocated |= s
        idle = len([d for d in allocated if st["dids_seen"].get(d, 0) == 0])
        w("\n  DIDs in dids.csv that took ZERO calls in this window: %d of %d ($%.2f/mo)\n"
          % (idle, len(allocated), idle * cost))
    w("\n  These do not net off. Moving a surplus number between pools is free;\n")
    w("  it is the same DID with the same reputation. Buying is not.\n")

    # --- 4. the totals ------------------------------------------------------
    w("\n--- 4. fleet size and cost by cap ---\n")
    w("  Every NPA sized to its own observed peak, so overflow is back to being\n")
    w("  a safety net rather than a load-bearing pool. Sizing overflow for the\n")
    w("  CURRENT spill as well would count the same calls twice: that spill only\n")
    w("  exists because the NPA pools are too small.\n\n")
    w("  %6s %10s %10s %10s %11s %11s %11s\n"
      % ("cap", "NPA DIDs", "overflow", "total", "net buy", "into NPAs", "$/month"))
    cur_total = (sum(r["pool_size"] for r in recs) + ofrec["pool_size"])
    for cap in caps:
        npa_need = sum(r["need_%d" % cap] for r in recs)
        of_need = overflow_min
        total = npa_need + of_need
        # Two different numbers, and the gap between them is the misallocation.
        # 'net buy' is how many more DIDs the fleet needs in total. 'into NPAs'
        # is how many have to end up in specific pools -- some of which can be
        # moved from an over-provisioned pool instead of bought.
        net = max(0, total - cur_total)
        into = sum(r["buy_%d" % cap] for r in recs)
        w("  %6d %10d %10d %10d %11d %11d %11.2f\n"
          % (cap, npa_need, of_need, total, net, into, total * cost))
    w("\n  current fleet %d DID(s) = $%.2f/month\n" % (cur_total, cur_total * cost))
    w("  overflow floored at %d (OVERFLOW_MIN): a thin overflow pool degrades\n" % overflow_min)
    w("  into the single-default-number failure this pool exists to prevent.\n")
    w("\n  Where 'net buy' is smaller than 'into NPAs', the fleet is big enough\n")
    w("  and in the wrong place. Move numbers between pools before buying --\n")
    w("  it is the same DID with the same reputation and it costs nothing.\n")
    w("\n  Cap is NOT modelled above %d. 200/day/DID is already aggressive for\n" % max(caps))
    w("  analytics reputation; the lever here is number count, not cap.\n\n")


def write_plan(path, recs, ofrec, caps, cost, overflow_min):
    fields = (["npa", "pool_size", "peak_daily_demand", "total_demand",
               "overflow_calls", "refused_calls", "has_dedicated_pool"]
              + ["need_at_cap_%d" % c for c in caps]
              + ["buy_at_cap_%d" % c for c in caps])
    fh = sys.stdout if path == "-" else open(path, "w", newline="")
    try:
        w = csv.writer(fh)
        w.writerow(fields)
        for r in recs:
            if r["total_demand"] == 0 and r["pool_size"] == 0:
                continue
            w.writerow([r["npa"], r["pool_size"], r["peak_daily_demand"],
                        r["total_demand"], r["overflow"], r["refused"],
                        "yes" if r["has_pool"] else "no"]
                       + [r["need_%d" % c] for c in caps]
                       + [r["buy_%d" % c] for c in caps])
        # Overflow is sized to the OVERFLOW_MIN floor, NOT to the spill it is
        # currently absorbing. The per-NPA rows above already buy the numbers
        # that spill consists of; sizing overflow for it as well would order
        # the same calls' worth of DIDs twice. peak_daily_demand still records
        # what overflow actually carried, so the as-is load is not lost.
        w.writerow(["OVERFLOW", ofrec["pool_size"], ofrec["peak_daily_demand"],
                    ofrec["total_demand"], "", "", "yes"]
                   + [overflow_min for _ in caps]
                   + [max(0, overflow_min - ofrec["pool_size"]) for _ in caps])
    finally:
        if fh is not sys.stdout:
            fh.close()


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--cdr", action="append", default=[])
    ap.add_argument("--dids", default="dids.csv")
    ap.add_argument("--window", type=int, default=0)
    ap.add_argument("--cap", type=int, default=200)
    ap.add_argument("--caps", default="200,150,100,75")
    ap.add_argument("--did-cost", type=float, default=0.50)
    ap.add_argument("--overflow-min", type=int, default=20)
    ap.add_argument("--headroom", type=float, default=0.0)
    ap.add_argument("--out", default="")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("-h", "--help", action="store_true")
    a = ap.parse_args()

    if a.help:
        sys.stdout.write(__doc__)
        return 0

    cdrs = a.cdr or ["/var/log/asterisk/cdr-custom/sbc.csv"]
    try:
        caps = sorted({int(c) for c in a.caps.split(",") if c.strip()}, reverse=True)
    except ValueError:
        die("--caps must be a comma-separated list of integers")
    if not caps:
        die("--caps produced no values")
    if max(caps) > 200:
        die("--caps includes %d. This tool models 200 and below on purpose:\n"
            "       200/day/DID is already aggressive for analytics reputation,\n"
            "       and the standing decision is more numbers, not a higher cap."
            % max(caps))

    pools = load_dids(a.dids)
    if pools is None:
        sys.stderr.write("  note: %s not found -- pool sizes and surplus unavailable\n" % a.dids)

    st = analyze(read_cdr(cdrs), a.window)
    recs = build_rows(st, pools, caps, a.headroom)
    ofrec = overflow_record(st, pools, caps, a.headroom)

    if not a.quiet:
        report(st, pools, recs, ofrec, caps, a.cap, a.did_cost, a.overflow_min)
    if a.out:
        write_plan(a.out, recs, ofrec, caps, a.did_cost, a.overflow_min)
        if a.out != "-":
            sys.stderr.write("  purchase plan: %s\n" % a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
