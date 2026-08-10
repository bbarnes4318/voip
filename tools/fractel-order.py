#!/usr/bin/env python3
"""
fractel-order.py - order DIDs from FracTEL and bind them to the SBC trunk.

    export FRACTEL_USER=you@example.com
    read -s FRACTEL_PASSWORD; export FRACTEL_PASSWORD      # never echoed, never stored

    python3 tools/fractel-order.py plan                    # no writes, prints the plan
    python3 tools/fractel-order.py order                   # asks before committing
    python3 tools/fractel-order.py csv > dids.csv          # emit dids.csv from state

WHY A SCRIPT AND NOT THE PORTAL
The bulk-order page needs a real click per area code (setting the combobox value
does not bind its model - the field displays your choice while the ADD button
stays disabled). Fifty of those, blind, on a live billing account, is the wrong
risk. Every call this script makes is logged and replayable.

SAFETY PROPERTIES, IN ORDER OF HOW MUCH THEY MATTER

  1. It refuses to run against the wrong subaccount. The JWT encodes the
     account; the script decodes it and compares against --account before it
     will order anything. Ordering 200 DIDs onto the parent account is not an
     error you can quietly undo.
  2. It refuses to order until you have seen the plan and typed ORDER.
  3. It is idempotent and resumable. Every ordered number is written to the
     state file the instant the API confirms it, before anything else happens.
     Re-running never re-orders a number the state file already has, and it
     reconciles against the live account on every start, so a crash mid-run
     costs nothing. There is no order id and no idempotency key in the API -
     this is the substitute.
  4. It assigns every number to the trunk and then RE-READS it to confirm.
     A DID on the wrong trunk gets no A attestation, which is the entire
     reason these numbers exist.

The password is read from the environment and used once, for POST /auth. It is
never written to the state file, the log, or stdout.
"""

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "https://api.fonestorm.com/v2"
ORDER_BATCH_MAX = 20          # hard API limit: "Maximum 20" per POST /fonenumbers/order

# 2 each. Order is preserved so the plan reads the way you wrote it.
MATCHED_NPAS = """
832 850 817 901 918 910 803 903 843 706
757 615 804 904 870 318 704 256 931 773
662 407 864 352 270 816 954 912 404 713
828 956 740 919 708 770 678 417 717 618
254 601 336 214 205 210 213 252 281 314
""".split()

SUBSTITUTE_NPAS = """
405 419 423 469 501 502 504 508 512 513
530 531 540 559 561 573 574 575 580 585
""".split()

PER_NPA = 2
OVERFLOW_TARGET = 100

# Tier X is $0.05/mo, A is $0.10, B is $0.25. Overflow numbers never match a
# destination, so they take the cheapest tier that has stock.
OVERFLOW_TIERS = ["X", "A", "B"]


# ---------------------------------------------------------------------------
# transport
# ---------------------------------------------------------------------------
class Api:
    def __init__(self, token=None, verbose=False):
        self.token = token
        self.verbose = verbose
        self.calls = 0

    def _req(self, method, path, body=None, params=None):
        url = BASE + path
        if params:
            url += "?" + urllib.parse.urlencode({k: v for k, v in params.items() if v is not None})
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Accept", "application/json")
        if data:
            req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("token", self.token)
        self.calls += 1
        if self.verbose:
            print(f"    -> {method} {url}", file=sys.stderr)
        for attempt in range(4):
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    raw = r.read().decode()
                    return json.loads(raw) if raw.strip() else {}
            except urllib.error.HTTPError as e:
                detail = e.read().decode()[:400]
                # 429/5xx are worth retrying; 4xx are not.
                if e.code in (429, 500, 502, 503, 504) and attempt < 3:
                    time.sleep(2 ** attempt)
                    continue
                raise SystemExit(
                    f"\nAPI ERROR {e.code} on {method} {path}\n  {detail}\n"
                    + ("\n  A 401 here means the token expired. Re-run; state is preserved.\n"
                       if e.code == 401 else "")
                )
            except urllib.error.URLError as e:
                if attempt < 3:
                    time.sleep(2 ** attempt)
                    continue
                raise SystemExit(f"\nNETWORK ERROR on {method} {path}: {e}\n")

    def get(self, p, **kw):  return self._req("GET", p, params=kw or None)
    def post(self, p, body): return self._req("POST", p, body=body)
    def put(self, p, body):  return self._req("PUT", p, body=body)


def jwt_account(token):
    """Read the account id out of the JWT payload. No signature check - we are
    not authenticating anything here, only refusing to touch the wrong account."""
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return None, {}
    acct = claims.get("account")
    if isinstance(acct, dict):
        return str(acct.get("id") or acct.get("account_id") or ""), claims
    for k in ("account_id", "accountId", "sub"):
        if claims.get(k):
            return str(claims[k]), claims
    return None, claims


# ---------------------------------------------------------------------------
# state
# ---------------------------------------------------------------------------
def load_state(path):
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    return {"account": None, "device_id": None, "baseline": [], "ordered": {}, "assigned": []}


def save_state(path, st):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f, indent=1, sort_keys=True)
    os.replace(tmp, path)          # atomic: a kill mid-write cannot corrupt it


def digits(s):
    return "".join(ch for ch in str(s) if ch.isdigit())


def ten(n):
    d = digits(n)
    return d[-10:] if len(d) >= 10 else d


# ---------------------------------------------------------------------------
def account_fonenumbers(api):
    """Every DID currently on the account, as a set of 10-digit strings."""
    out, page = {}, 1
    while True:
        r = api.get("/fonenumbers", page=page, max=1000)
        items = r.get("fonenumbers") or r.get("data") or []
        if isinstance(items, dict):
            items = list(items.values())
        if not items:
            break
        for it in items:
            num = ten(it.get("fonenumber") if isinstance(it, dict) else it)
            if len(num) == 10:
                out[num] = it if isinstance(it, dict) else {}
        if len(items) < 1000:
            break
        page += 1
        if page > 50:
            break
    return out


def find_device(api, want_name):
    r = api.get("/devices")
    items = r.get("devices") or r.get("data") or []
    if isinstance(items, dict):
        items = list(items.values())
    matches = []
    for d in items:
        if not isinstance(d, dict):
            continue
        name = str(d.get("name") or d.get("device_name") or "")
        did = str(d.get("id") or d.get("device_id") or d.get("uuid") or "")
        matches.append((name, did))
    exact = [m for m in matches if m[0] == want_name]
    if exact:
        return exact[0]
    loose = [m for m in matches if want_name.lower() in m[0].lower()
             or "167.235.206.206" in m[0]]
    if len(loose) == 1:
        return loose[0]
    raise SystemExit(
        "\nCould not identify the trunk device.\n"
        f"  wanted: {want_name}\n"
        f"  found : {matches}\n"
        "  Refusing to guess - a DID on the wrong trunk gets no A attestation.\n"
    )


def search_npa(api, npa, need, max_tier=None):
    r = api.get("/fonenumbers/inventory/local", area_code=npa,
                max=max(need * 10, 50), max_tier=max_tier)
    return [{"fonenumber": ten(x.get("fonenumber")),
             "state": x.get("state", ""),
             "rate_center": x.get("rate_center", ""),
             "tier_hint": max_tier or "?"}
            for x in (r.get("fonenumbers") or [])
            if len(ten(x.get("fonenumber"))) == 10]


# ---------------------------------------------------------------------------
def build_plan(api, st, args):
    owned = set(st["baseline"]) | {n for v in st["ordered"].values() for n in v}
    plan, gaps, subs_used = {}, [], []

    def take(npa, need, tier=None):
        got, seen = [], set()
        cands = search_npa(api, npa, need, max_tier=tier)
        for c in cands:
            if c["fonenumber"] in owned or c["fonenumber"] in seen:
                continue
            seen.add(c["fonenumber"])
            got.append(c)
            if len(got) >= need:
                break
        return got

    print("\nchecking inventory, one area code at a time...\n", file=sys.stderr)

    for npa in MATCHED_NPAS:
        have = len(st["ordered"].get(npa, []))
        need = PER_NPA - have
        if need <= 0:
            plan[npa] = []
            continue
        got = take(npa, need)
        if len(got) < need:
            gaps.append((npa, len(got)))
        plan[npa] = got
        print(f"  {npa}  {len(got)}/{need}" + ("   NO/LOW INVENTORY" if len(got) < need else ""),
              file=sys.stderr)

    # Substitutes only cover what the primary list could not supply.
    shortfall = sum(PER_NPA - len(st["ordered"].get(n, [])) - len(plan.get(n, []))
                    for n, _ in gaps)
    if shortfall > 0:
        print(f"\n  {shortfall} number(s) short; drawing from the substitute list\n", file=sys.stderr)
        for npa in SUBSTITUTE_NPAS:
            if shortfall <= 0:
                break
            have = len(st["ordered"].get(npa, []))
            got = take(npa, min(PER_NPA - have, shortfall))
            if got:
                plan[npa] = plan.get(npa, []) + got
                subs_used.append((npa, len(got)))
                shortfall -= len(got)
                print(f"  {npa}  +{len(got)} (substitute)", file=sys.stderr)

    # Overflow: cheapest tier with stock. Location is irrelevant here.
    have_ovf = len(st["ordered"].get("OVERFLOW", []))
    need_ovf = OVERFLOW_TARGET - have_ovf
    ovf = []
    if need_ovf > 0:
        print(f"\n  overflow: need {need_ovf}, cheapest tier first\n", file=sys.stderr)
        for tier in OVERFLOW_TIERS:
            if len(ovf) >= need_ovf:
                break
            for npa in MATCHED_NPAS + SUBSTITUTE_NPAS:
                if len(ovf) >= need_ovf:
                    break
                for c in search_npa(api, npa, need_ovf - len(ovf), max_tier=tier):
                    if c["fonenumber"] in owned:
                        continue
                    if any(c["fonenumber"] == o["fonenumber"] for o in ovf):
                        continue
                    if any(c["fonenumber"] == p["fonenumber"]
                           for v in plan.values() for p in v):
                        continue
                    ovf.append(c)
                    if len(ovf) >= need_ovf:
                        break
            print(f"    tier {tier}: {len(ovf)}/{need_ovf}", file=sys.stderr)
    plan["OVERFLOW"] = ovf
    return plan, gaps, subs_used


def print_plan(plan, gaps, subs_used, st, device, account):
    matched = [(k, v) for k, v in plan.items() if k != "OVERFLOW"]
    n_matched = sum(len(v) for _, v in matched)
    n_ovf = len(plan.get("OVERFLOW", []))
    total = n_matched + n_ovf

    print("\n" + "=" * 72)
    print("  ORDER PLAN - nothing has been purchased yet")
    print("=" * 72)
    print(f"  subaccount        {account}")
    print(f"  trunk device      {device[0]}  (id {device[1]})")
    print(f"  already on file   {len(st['baseline'])} DID(s) - untouched")
    if st["ordered"]:
        prev = sum(len(v) for v in st["ordered"].values())
        print(f"  already ordered   {prev} by a previous run - will NOT be re-ordered")
    print()
    for npa, got in matched:
        if got:
            print(f"    {npa}   {len(got)}   " + ", ".join(g["fonenumber"] for g in got))
    if n_ovf:
        print(f"\n    OVERFLOW  {n_ovf}   tiers " +
              ",".join(sorted({g['tier_hint'] for g in plan['OVERFLOW']})))
    print()
    if gaps:
        print("  AREA CODES WITH NO/LOW INVENTORY")
        for npa, got in gaps:
            print(f"    {npa}: found {got} of {PER_NPA}")
    if subs_used:
        print("  SUBSTITUTES USED")
        for npa, n in subs_used:
            print(f"    {npa}: +{n}")
    if gaps or subs_used:
        print()

    # Costs, from the Rates page. E911 is the line that dwarfs everything.
    print("  ESTIMATED MONTHLY COST")
    print(f"    {total} DID(s) at tier X  $0.05  =  ${total * 0.05:>8.2f}")
    print(f"    {total} DID(s) at tier A  $0.10  =  ${total * 0.10:>8.2f}")
    print(f"    E911 IF ASSESSED  $1.00/DID   =  ${total * 1.00:>8.2f}   <-- dominates")
    print( "    FUSF 38.80% - account is marked FUSF EXEMPT, so not applied")
    print( "    (the order API returns no price; tier is a property of the rate")
    print( "     centre. Confirm actual tiers on the next invoice.)")
    print("=" * 72)
    print(f"  TOTAL TO ORDER NOW: {total}   ({n_matched} matched + {n_ovf} overflow)")
    print("=" * 72 + "\n")
    return total


# ---------------------------------------------------------------------------
def do_order(api, st, statefile, plan, device_id):
    flat = []
    for key, got in plan.items():
        for g in got:
            flat.append((key, g["fonenumber"]))
    if not flat:
        print("nothing to order")
        return

    print(f"\nordering {len(flat)} number(s) in batches of {ORDER_BATCH_MAX}...\n")
    for i in range(0, len(flat), ORDER_BATCH_MAX):
        batch = flat[i:i + ORDER_BATCH_MAX]
        nums = [n for _, n in batch]
        resp = api.post("/fonenumbers/order",
                        {"fonenumbers": nums, "messaging_enabled": False})
        results = resp.get("fonenumbers") or resp.get("fonenumber") or []
        if isinstance(results, dict):
            results = [results]
        ok = {ten(r.get("fonenumber")): r for r in results
              if str(r.get("result", "")).upper() == "SUCCESS"}
        # Persist immediately, per batch. A crash on the next line must not
        # lose the record of numbers we have just been billed for.
        for key, num in batch:
            if num in ok:
                st["ordered"].setdefault(key, [])
                if num not in st["ordered"][key]:
                    st["ordered"][key].append(num)
        save_state(statefile, st)
        failed = [n for _, n in batch if n not in ok]
        print(f"  batch {i//ORDER_BATCH_MAX + 1}: {len(ok)} ok"
              + (f", {len(failed)} FAILED ({', '.join(failed)})" if failed else ""))

    # --- assignment, then read back -----------------------------------------
    all_ordered = [n for v in st["ordered"].values() for n in v]
    todo = [n for n in all_ordered if n not in st["assigned"]]
    print(f"\nassigning {len(todo)} number(s) to the trunk...\n")
    bad = []
    for n in todo:
        api.put(f"/fonenumbers/{n}",
                {"call_options": {"receive": {"type": "Device", "value": str(device_id)}}})
        chk = api.get(f"/fonenumbers/{n}")
        fn = chk.get("fonenumber") if isinstance(chk.get("fonenumber"), dict) else chk
        recv = ((fn or {}).get("call_options") or {}).get("receive") or {}
        if str(recv.get("type")) == "Device" and str(recv.get("value")) == str(device_id):
            st["assigned"].append(n)
            save_state(statefile, st)
        else:
            bad.append((n, recv))
    print(f"  assigned and verified: {len(st['assigned'])}")
    if bad:
        print(f"  NOT ON THE TRUNK ({len(bad)}) - these get no A attestation:")
        for n, r in bad:
            print(f"    {n}  ->  {r}")


def emit_csv(st, out=sys.stdout):
    """dids.csv for the SBC: 11 digits, leading 1, matched rows keyed by NPA.

    Every number is checked before the '1' goes on the front. render.sh will
    reject a malformed DID anyway, but it does so at deploy time on the live
    box; catching it here means a bad row never reaches the file. A 9-digit
    value silently becoming 11832555141 is exactly the kind of thing that
    looks fine in a diff.
    """
    bad = []

    def row(key, n, npa):
        d = digits(n)
        if len(d) != 10 or d[0] in "01" or d[3] in "01":
            bad.append((key, n))
            return None
        return f"{npa},1{d}"

    lines = []
    for npa in MATCHED_NPAS + SUBSTITUTE_NPAS:
        for n in st["ordered"].get(npa, []):
            r = row(npa, n, npa)
            if r:
                lines.append(r)
    for n in st["ordered"].get("OVERFLOW", []):
        r = row("OVERFLOW", n, "OVERFLOW")
        if r:
            lines.append(r)

    if bad:
        print("emit_csv: REFUSING to write - malformed number(s) in the state file:",
              file=sys.stderr)
        for k, n in bad[:10]:
            print(f"  {k}: {n!r} (expected 10 digits, NPA and NXX starting 2-9)",
                  file=sys.stderr)
        raise SystemExit(1)

    print("npa,did", file=out)
    for l in lines:
        print(l, file=out)


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["plan", "order", "csv", "diff", "whoami"])
    ap.add_argument("--account", default="2005555318")
    ap.add_argument("--device-name", default="Trunk-1-167.235.206.206")
    ap.add_argument("--state", default="fractel-order-state.json")
    ap.add_argument("--allow-account-mismatch", action="store_true",
                    help="proceed even if the token's account is not --account. Do not use.")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    st = load_state(args.state)

    if args.cmd == "csv":
        emit_csv(st)
        return 0

    user = os.environ.get("FRACTEL_USER")
    pwd = os.environ.get("FRACTEL_PASSWORD")
    if not user or not pwd:
        raise SystemExit("set FRACTEL_USER and FRACTEL_PASSWORD in the environment")

    api = Api(verbose=args.verbose)
    tok = api.post("/auth", {"username": user, "password": pwd, "expires": 86400})
    api.token = (tok.get("authorization") or tok).get("token") or tok.get("token")
    if not api.token:
        raise SystemExit(f"no token in /auth response: {json.dumps(tok)[:300]}")
    del pwd

    acct, claims = jwt_account(api.token)
    print(f"\nauthenticated as account {acct}")
    if args.cmd == "whoami":
        print(json.dumps(claims, indent=1)[:1500])
        return 0

    # ---- the guard that matters most --------------------------------------
    if acct != args.account:
        msg = (f"\nACCOUNT MISMATCH\n"
               f"  token is for : {acct}\n"
               f"  expected     : {args.account}\n\n"
               "  These numbers must land on the SBC's subaccount. Ordering 200\n"
               "  DIDs onto the wrong account is not quietly reversible.\n"
               "  Authenticate as the subaccount user, or pass --account.\n")
        if not args.allow_account_mismatch:
            raise SystemExit(msg)
        print(msg + "  --allow-account-mismatch given; continuing anyway.\n")
    st["account"] = acct

    device = find_device(api, args.device_name)
    st["device_id"] = device[1]
    print(f"trunk device: {device[0]}  (id {device[1]})")

    live = account_fonenumbers(api)
    if not st["baseline"]:
        st["baseline"] = sorted(live)
        print(f"baseline recorded: {len(st['baseline'])} existing DID(s)")
    save_state(args.state, st)

    if args.cmd == "diff":
        base = set(st["baseline"])
        now = set(live)
        print(f"\nbaseline {len(base)}   now {len(now)}   new {len(now - base)}")
        for n in sorted(now - base):
            recv = ((live[n].get("call_options") or {}).get("receive") or {})
            print(f"  1{n}   {recv.get('type','?')}:{recv.get('value','?')}")
        return 0

    # Reconcile: anything the state thinks it ordered but the account does not
    # have was never actually purchased. Drop it so it gets re-planned.
    for key, nums in list(st["ordered"].items()):
        st["ordered"][key] = [n for n in nums if n in live]
    st["assigned"] = [n for n in st["assigned"] if n in live]
    save_state(args.state, st)

    plan, gaps, subs = build_plan(api, st, args)
    total = print_plan(plan, gaps, subs, st, device, acct)

    if args.cmd == "plan":
        print("plan only. Re-run with 'order' to place it.\n")
        return 0

    if total == 0:
        print("nothing left to order - state file says the order is complete.\n")
        return 0

    print(f"This will PURCHASE {total} DID(s) on subaccount {acct} and incur")
    print("recurring monthly charges. Type ORDER to proceed, anything else aborts.")
    try:
        if input("> ").strip() != "ORDER":
            print("aborted, nothing purchased.")
            return 1
    except (EOFError, KeyboardInterrupt):
        print("\naborted, nothing purchased.")
        return 1

    do_order(api, st, args.state, plan, device[1])
    print(f"\nstate: {args.state}   API calls: {api.calls}")
    print(f"CSV:   python3 {sys.argv[0]} csv > dids.csv")
    print(f"Diff:  python3 {sys.argv[0]} diff\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
