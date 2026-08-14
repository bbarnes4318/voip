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
        # did_daily_peak[did][day] = highest did_daily_count_at_selection seen.
        # That column includes the call it is on, so its maximum for a day IS
        # that number's call count for the day -- no need to re-count rows, and
        # it stays correct even if the CDR is a partial slice.
        "did_daily_peak": defaultdict(lambda: defaultdict(int)),
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
            try:
                c = int(r[C_DIDCOUNT])
            except (ValueError, IndexError):
                c = 0
            if c > st["did_daily_peak"][did][day]:
                st["did_daily_peak"][did][day] = c

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


# ---------------------------------------------------------------------------
# Reallocation
#
# A DID that already exists moves between pools for free and keeps whatever
# reputation it has. A purchased one costs money AND arrives unseasoned. So the
# plan has to say which of the two each number is, per NPA, or a vendor handed
# the file orders numbers the operator already owns -- and swaps seasoned
# numbers for fresh ones in the process, which is the opposite of the intent.
# ---------------------------------------------------------------------------
EXPERIMENT_NPAS = ("336", "337", "316", "609")


def donor_retain(need):
    """What a donor keeps: max(need + 2, ceil(need * 1.25)).

    A donor must NOT be drained to exactly its need. `need` is derived from the
    peak of a three-day window whose highest-volume day (2026-08-10) was a
    PARTIAL day starting 13:23 -- so it is a floor, not an estimate. The surplus
    those pools were carrying is what has been absorbing demand variance.
    Draining every donor onto its floor turns the first busier-than-measured day
    into simultaneous refusals across every pool that gave numbers away.

    Both terms matter: +2 protects small pools, where 25% of 1 rounds to nothing,
    and 1.25x protects large ones, where +2 is noise.
    """
    return max(need + 2, int(math.ceil(need * 1.25)))


def overflow_need(st, recs, plan, ofrec, cap, overflow_min):
    """How many DIDs overflow must keep to absorb the spill left after `plan`.

    OVERFLOW_MIN is a FLOOR, not overflow's need. Overflow is the only pool that
    is fungible: one number in it can serve any of the 293 NPAs that have no
    pool of their own, whereas the same number moved into a dedicated pool can
    serve exactly one. So its real need is the peak daily spill it still has to
    carry, and draining below that trades shared capacity for stranded capacity.

    Getting this wrong is not a rounding error. Treating OVERFLOW_MIN as the
    need made the projected refusals at cap 150 and below WORSE after
    reallocation than before it -- the reallocation was actively destroying
    capacity while reporting itself as free.
    """
    sizes = {r["npa"]: r["pool_size"] for r in recs}
    for npa, p in plan.items():
        sizes[npa] = sizes.get(npa, 0) + p["realloc"]
    worst = 0
    for day in st["days"]:
        spill = 0
        for npa, perday in st["demand"].items():
            d = perday.get(day, 0)
            if d:
                spill += max(0, d - sizes.get(npa, 0) * cap)
        worst = max(worst, spill)
    return max(overflow_min, int(math.ceil(worst / float(cap))))


def plan_reallocation(recs, ofrec, cap, overflow_min, priority=EXPERIMENT_NPAS,
                      st=None):
    """Match existing surplus DIDs to shortfalls. Never invents a purchase."""
    donors = []
    for r in recs:
        surplus = r["pool_size"] - donor_retain(r["need_%d" % cap])
        if surplus > 0:
            donors.append([r["npa"], surplus])
    donors.sort(key=lambda d: -d[1])

    # Overflow donates only what it is genuinely NOT using. Computed in two
    # passes because its need depends on what the NPA-surplus pass leaves
    # unprovisioned: plan from NPA surplus alone first, measure the residual
    # spill, and only then decide whether any overflow number is actually idle.
    # In practice this is usually zero, which is the correct answer -- moving a
    # number out of a pool serving 293 NPAs into one serving a single NPA is a
    # downgrade unless that number was doing nothing.
    if st is not None:
        first = _match(recs, donors, cap, priority)
        need = overflow_need(st, recs, first, ofrec, cap, overflow_min)
        of_surplus = max(0, ofrec["pool_size"] - need)
        if of_surplus > 0:
            donors.append(["OVERFLOW", of_surplus])

    return _match(recs, donors, cap, priority)


def _match(recs, donors, cap, priority):
    donors = [list(d) for d in donors]   # never mutate the caller's tallies
    short = [r for r in recs if r["need_%d" % cap] > r["pool_size"]]
    # The four worst per-DID loads go first, so the reallocation doubles as the
    # burned-number experiment: if their answer rate moves and nothing else
    # changed, DID reputation outranks routing.
    rank = {n: i for i, n in enumerate(priority)}
    short.sort(key=lambda r: (rank.get(r["npa"], len(rank)),
                              -(r["need_%d" % cap] - r["pool_size"])))

    out = {}
    di = 0
    for r in short:
        want = r["need_%d" % cap] - r["pool_size"]
        got, sources = 0, []
        while want > got and di < len(donors):
            avail = donors[di][1]
            if avail <= 0:
                di += 1
                continue
            take = min(avail, want - got)
            donors[di][1] -= take
            sources.append((donors[di][0], take))
            got += take
        out[r["npa"]] = {
            "realloc": got,
            "buy": want - got,
            "from": sources,
            "priority": r["npa"] in rank,
        }
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


# ---------------------------------------------------------------------------
# Refusal projection
#
# Every refusal in the measured window was produced under a cap of 600, so the
# fleet had three times the capacity it has under the standing cap of 200.
# 36,683 refusals is therefore a FLOOR, not a baseline: the same demand against
# the same fleet at cap 200 refuses far more.
#
# Peak-demand arithmetic is unaffected by that -- peak demand is peak demand,
# and need_at_cap_200 is computed from demand rather than from refusals. What
# changes is the answer to "does reallocation alone hold, or does the purchase
# have to land before the trunk comes back up".
#
# The model replays each day: a call takes its own NPA pool if that pool has
# allowance left, else overflow, else it is refused. Daily order does not matter
# for a DAILY cap -- a pool serves min(demand, pool * cap) that day regardless
# of when the calls arrive -- so aggregating by day is exact, not an
# approximation.
# ---------------------------------------------------------------------------

def simulate_refusals(st, npa_pool, overflow_pool, cap):
    """-> (total_refused, total_demand, {day: (spill, refused)})"""
    total_ref = total_dem = 0
    per_day = {}
    for day in sorted(st["days"]):
        spill = dem = 0
        for npa, perday in st["demand"].items():
            d = perday.get(day, 0)
            if not d:
                continue
            dem += d
            spill += max(0, d - npa_pool.get(npa, 0) * cap)
        refused = max(0, spill - overflow_pool * cap)
        per_day[day] = (spill, refused)
        total_ref += refused
        total_dem += dem
    return total_ref, total_dem, per_day


def post_realloc_pools(recs, ofrec, plan, pools, overflow_min, cap):
    """Pool sizes after the reallocation plan is applied. No purchases."""
    sizes = {r["npa"]: r["pool_size"] for r in recs}
    of = ofrec["pool_size"]
    for npa, p in plan.items():
        sizes[npa] = sizes.get(npa, 0) + p["realloc"]
        for src, n in p["from"]:
            if src == "OVERFLOW":
                of -= n
            else:
                sizes[src] = sizes.get(src, 0) - n
    return sizes, max(of, 0)


def project_refusals(st, pools, recs, ofrec, caps, overflow_min, out=sys.stdout):
    w = out.write
    w("\n=== projected refusals by cap and fleet ===\n")
    w("\n  Measured refusals came from a window running at cap 600. At 200 the\n")
    w("  same demand meets a third of the per-pool ceiling, so these are the\n")
    w("  numbers that decide whether reallocation alone is enough.\n\n")
    cur_npa = {r["npa"]: r["pool_size"] for r in recs}
    cur_of = ofrec["pool_size"]

    w("  %6s  %-22s %10s %10s %9s\n"
      % ("cap", "fleet", "demand", "refused", "% lost"))
    for cap in caps:
        plan = plan_reallocation(recs, ofrec, cap, overflow_min, st=st)
        ra_npa, ra_of = post_realloc_pools(recs, ofrec, plan, pools, overflow_min, cap)
        # Purchase scenario: every NPA at its own need, overflow back to floor.
        buy_npa = {r["npa"]: max(r["pool_size"], r["need_%d" % cap]) for r in recs}

        for label, np_, of_ in (
                ("current fleet", cur_npa, cur_of),
                ("after reallocation", ra_npa, ra_of),
                ("after purchase", buy_npa, max(cur_of, overflow_min)),
        ):
            ref, dem, _ = simulate_refusals(st, np_, of_, cap)
            w("  %6s  %-22s %10d %10d %8.1f%%\n"
              % (cap if label == "current fleet" else "", label, dem, ref,
                 100.0 * ref / dem if dem else 0.0))
        w("\n")

    # The decision this exists to answer.
    plan200 = plan_reallocation(recs, ofrec, 200, overflow_min, st=st)
    ra_npa, ra_of = post_realloc_pools(recs, ofrec, plan200, pools, overflow_min, 200)
    ref_cur, dem, _ = simulate_refusals(st, cur_npa, cur_of, 200)
    ref_ra, _, _ = simulate_refusals(st, ra_npa, ra_of, 200)
    buy_npa = {r["npa"]: max(r["pool_size"], r["need_200"]) for r in recs}
    ref_buy, _, _ = simulate_refusals(st, buy_npa, max(cur_of, overflow_min), 200)
    w("  At cap 200 against this demand:\n")
    w("    current fleet       %7d refused  (%.1f%%)\n"
      % (ref_cur, 100.0 * ref_cur / dem if dem else 0))
    w("    after reallocation  %7d refused  (%.1f%%)   %+d\n"
      % (ref_ra, 100.0 * ref_ra / dem if dem else 0, ref_ra - ref_cur))
    w("    after purchase      %7d refused  (%.1f%%)   %+d\n"
      % (ref_buy, 100.0 * ref_buy / dem if dem else 0, ref_buy - ref_cur))
    if ref_ra > 0:
        w("\n    Reallocation alone does NOT clear refusals at cap 200. The\n")
        w("    purchase has to land before the trunk comes back up, or the\n")
        w("    box refuses %d call(s) against this demand.\n" % ref_ra)
    else:
        w("\n    Reallocation alone clears refusals at cap 200 against this\n")
        w("    demand. The purchase buys headroom, not recovery.\n")
    w("\n  Caveat: demand here is OFFERED load from the measured window, which\n")
    w("  includes the calls that were refused. It does not include demand the\n")
    w("  dialer suppressed after being refused, so this is still a floor.\n\n")


def load_report(st, pools, cap, out=sys.stdout):
    """Calls per DID per day, and which numbers sit pinned at the cap.

    A number running at the cap every day, dialling into its own area code, is
    the profile call-analytics engines score on. This is the view that tests
    whether the worst-answering NPAs are the ones whose two or three numbers
    are burned -- so it reports per-DID load and consecutive capped days, not
    just totals.
    """
    w = out.write
    days = sorted(st["days"])
    w("\n=== load per DID ===\n")

    # --- per NPA ------------------------------------------------------------
    w("\n--- calls per DID per day, by NPA (worst 25) ---\n")
    w("  %-6s %5s %10s %12s %10s\n"
      % ("NPA", "pool", "peak/day", "per DID/day", "vs cap"))
    rows = []
    for npa, perday in st["demand"].items():
        pool = len(pools[npa]) if pools and npa in pools else 0
        if pool == 0:
            continue
        pk = peak(perday)
        rows.append((pk / float(pool), npa, pool, pk))
    rows.sort(reverse=True)
    for per, npa, pool, pk in rows[:25]:
        w("  %-6s %5d %10d %12.0f %10s\n"
          % (npa, pool, pk, per, "OVER" if per > cap else ""))
    if rows:
        med = sorted(r[0] for r in rows)[len(rows) // 2]
        w("\n  median %.0f calls/DID/day across %d pooled NPA(s); %d over the %d cap\n"
          % (med, len(rows), len([r for r in rows if r[0] > cap]), cap))

    # --- per individual DID -------------------------------------------------
    # did_daily_count_at_selection includes the call it is on, so a row equal
    # to the cap means that number took its last call of the day.
    w("\n--- individual DIDs at the cap ---\n")
    capped_days = defaultdict(set)
    maxcount = defaultdict(int)
    for did, peak_by_day in st["did_daily_peak"].items():
        for day, c in peak_by_day.items():
            if c >= cap:
                capped_days[did].add(day)
            if c > maxcount[did]:
                maxcount[did] = c
    for day in days:
        n = len([d for d in capped_days if day in capped_days[d]])
        w("  %s  %d DID(s) reached the %d cap\n" % (day, n, cap))
    if capped_days:
        w("\n  %-14s %8s %10s %s\n" % ("DID", "peak/day", "days@cap", "which"))
        for did in sorted(capped_days, key=lambda d: (-len(capped_days[d]), -maxcount[d]))[:20]:
            w("  %-14s %8d %10d %s\n"
              % (did, maxcount[did], len(capped_days[did]),
                 ",".join(sorted(capped_days[did]))))
        w("\n  %d of %d DID(s) that carried traffic hit the cap on at least one day.\n"
          % (len(capped_days), len(st["dids_seen"])))
        w("  Consecutive capped days is the number that matters: a number pinned\n")
        w("  at the ceiling day after day is the one an analytics engine scores.\n")
    else:
        w("  no DID reached the cap in this window\n")
    w("\n  This is evidence for LOWERING the cap once fleet size allows, not for\n")
    w("  raising it. A number over the cap is not a number working harder; it is\n")
    w("  a number more likely to be labelled.\n\n")


def write_plan(path, recs, ofrec, caps, cost, overflow_min, cur_cap, st):
    # buy_at_cap_* is NET OF REALLOCATION: summing it gives the vendor order and
    # nothing else. reallocate_at_cap_* is what moves between pools we already
    # own. The two together equal the shortfall.
    plans = {c: plan_reallocation(recs, ofrec, c, overflow_min, st=st) for c in caps}
    fields = (["npa", "pool_size", "peak_daily_demand", "total_demand",
               "overflow_calls", "refused_calls", "has_dedicated_pool"]
              + ["need_at_cap_%d" % c for c in caps]
              + ["reallocate_at_cap_%d" % c for c in caps]
              + ["buy_at_cap_%d" % c for c in caps]
              + ["reallocate_from_at_cap_%d" % cur_cap, "provision_order"])
    fh = sys.stdout if path == "-" else open(path, "w", newline="")
    try:
        w = csv.writer(fh)
        w.writerow(fields)
        # Experiment NPAs first, then whatever needs the most. The row order IS
        # the provisioning order: 336/337/316/609 are the four worst per-DID
        # loads, and doing them before anything else is what makes the
        # reallocation a test of the burned-number hypothesis.
        cur = plans[cur_cap]
        ordered = sorted(
            (r for r in recs if r["total_demand"] or r["pool_size"]),
            key=lambda r: (0 if cur.get(r["npa"], {}).get("priority") else 1,
                           -(cur.get(r["npa"], {}).get("realloc", 0)
                             + cur.get(r["npa"], {}).get("buy", 0)),
                           r["npa"]))
        for i, r in enumerate(ordered, 1):
            p = cur.get(r["npa"], {})
            src = "|".join("%s:%d" % (s, n) for s, n in p.get("from", []))
            w.writerow([r["npa"], r["pool_size"], r["peak_daily_demand"],
                        r["total_demand"], r["overflow"], r["refused"],
                        "yes" if r["has_pool"] else "no"]
                       + [r["need_%d" % c] for c in caps]
                       + [plans[c].get(r["npa"], {}).get("realloc", 0) for c in caps]
                       + [plans[c].get(r["npa"], {}).get("buy", 0) for c in caps]
                       + [src, i])
        # Overflow is sized to the OVERFLOW_MIN floor, NOT to the spill it is
        # currently absorbing. The per-NPA rows above already buy the numbers
        # that spill consists of; sizing overflow for it as well would order
        # the same calls' worth of DIDs twice. peak_daily_demand still records
        # what overflow actually carried, so the as-is load is not lost.
        w.writerow(["OVERFLOW", ofrec["pool_size"], ofrec["peak_daily_demand"],
                    ofrec["total_demand"], "", "", "yes"]
                   + [overflow_min for _ in caps]
                   + [0 for _ in caps]
                   + [max(0, overflow_min - ofrec["pool_size"]) for _ in caps]
                   + ["(donor)", len(ordered) + 1])
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
    ap.add_argument("--load-report", action="store_true")
    ap.add_argument("--project-refusals", action="store_true")
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
        if a.load_report:
            load_report(st, pools, a.cap)
        elif a.project_refusals:
            project_refusals(st, pools, recs, ofrec, caps, a.overflow_min)
        else:
            report(st, pools, recs, ofrec, caps, a.cap, a.did_cost, a.overflow_min)
    if a.out:
        write_plan(a.out, recs, ofrec, caps, a.did_cost, a.overflow_min, a.cap, st)
        if a.out != "-":
            sys.stderr.write("  purchase plan: %s\n" % a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
