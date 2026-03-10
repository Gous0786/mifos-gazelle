#!/usr/bin/env python3
"""
verify-bulk-batches.py

Submits and verifies all 4 non-Mastercard bulk batch scenarios via the
operations-app REST API (no direct DB access):

  1. Mojaloop  / Non-GovStack  (tenant: greenbank)
  2. Closedloop / Non-GovStack  (tenant: redbank)
  3. Mojaloop  / GovStack       (tenant: greenbank --govstack)
  4. Closedloop / GovStack       (tenant: redbank   --govstack)

Batch status is checked via:
  GET https://ops.{domain}/api/v1/batch/{batchId}?command=aggregate
  GET https://ops.{domain}/api/v1/batch/detail?batchId={batchId}

Usage:
  ./verify-bulk-batches.py                    # uses ~/tomconfig.ini
  ./verify-bulk-batches.py -c ~/myconfig.ini
  ./verify-bulk-batches.py --timeout 180
"""

import sys
import re
import time
import argparse
import subprocess
import configparser
import requests
import urllib3
from pathlib import Path

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ---------------------------------------------------------------------------
# Paths / constants
# ---------------------------------------------------------------------------
SCRIPT_DIR    = Path(__file__).parent
DEFAULT_CFG   = Path.home() / "tomconfig.ini"
MOJALOOP_CSV  = SCRIPT_DIR / "bulk-gazelle-mojaloop-4.csv"
CLOSEDLOOP_CSV = SCRIPT_DIR / "bulk-gazelle-closedloop-4.csv"

SCENARIOS = [
    {
        "name":     "Mojaloop / Non-GovStack",
        "csv":      MOJALOOP_CSV,
        "tenant":   "greenbank",
        "govstack": False,
    },
    {
        "name":     "Closedloop / Non-GovStack",
        "csv":      CLOSEDLOOP_CSV,
        "tenant":   "redbank",
        "govstack": False,
    },
    {
        "name":     "Mojaloop / GovStack",
        "csv":      MOJALOOP_CSV,
        "tenant":   "greenbank",
        "govstack": True,
    },
    {
        "name":     "Closedloop / GovStack",
        "csv":      CLOSEDLOOP_CSV,
        "tenant":   "redbank",
        "govstack": True,
    },
]

# ---------------------------------------------------------------------------
# ANSI colours
# ---------------------------------------------------------------------------
GREEN  = "\033[92m"
RED    = "\033[91m"
YELLOW = "\033[93m"
CYAN   = "\033[96m"
BOLD   = "\033[1m"
RESET  = "\033[0m"

def ok(msg):   return f"{GREEN}✓ {msg}{RESET}"
def fail(msg): return f"{RED}✗ {msg}{RESET}"
def warn(msg): return f"{YELLOW}⚠ {msg}{RESET}"
def info(msg): return f"{CYAN}{msg}{RESET}"
def bold(msg): return f"{BOLD}{msg}{RESET}"


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
def load_domain(config_path):
    cfg = configparser.ConfigParser()
    cfg.read(config_path)
    try:
        return cfg.get("general", "GAZELLE_DOMAIN")
    except (configparser.NoSectionError, configparser.NoOptionError):
        print(fail(f"GAZELLE_DOMAIN not found in {config_path}"))
        sys.exit(1)


# ---------------------------------------------------------------------------
# Batch submission  (delegates to submit-batch.py)
# ---------------------------------------------------------------------------
def submit_batch(scenario, config_path):
    """
    Run submit-batch.py as a subprocess.
    Returns (batch_id: str|None, stderr: str, returncode: int).
    Batch ID is extracted from the PollingPath in the JSON response.
    """
    cmd = [
        sys.executable,
        str(SCRIPT_DIR / "submit-batch.py"),
        "-f", str(scenario["csv"]),
        "--tenant", scenario["tenant"],
        "-c", str(config_path),
    ]
    if scenario["govstack"]:
        cmd.append("--govstack")

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return None, "subprocess timed out after 120s", 1

    # submit-batch.py writes everything to stderr
    stderr = result.stderr

    # PollingPath looks like: "/batch/Summary/<uuid>"
    batch_id = None
    match = re.search(r'"PollingPath"\s*:\s*"/batch/Summary/([^"]+)"', stderr)
    if match:
        batch_id = match.group(1)

    return batch_id, stderr, result.returncode


# ---------------------------------------------------------------------------
# Operations-app API helpers
# ---------------------------------------------------------------------------
def _ops_get(url, tenant, timeout=15):
    """GET from ops API with Platform-TenantId header. Returns parsed JSON or None."""
    try:
        resp = requests.get(
            url,
            headers={"Platform-TenantId": tenant},
            verify=False,
            timeout=timeout,
        )
        if resp.status_code == 200:
            return resp.json()
        return None
    except Exception:
        return None


def fetch_batch_summary(domain, batch_id, tenant):
    """
    Call GET /api/v1/batch/{batchId}?command=aggregate
    Returns dict with: total, successful, failed, ongoing, status, etc.
    """
    url = f"https://ops.{domain}/api/v1/batch/{batch_id}?command=aggregate"
    return _ops_get(url, tenant)


def fetch_batch_transfers(domain, batch_id, tenant, page_size=20):
    """
    Call GET /api/v1/batch/detail?batchId={batchId}
    Returns list of transfer dicts, or [].
    """
    url = f"https://ops.{domain}/api/v1/batch/detail?batchId={batch_id}&pageSize={page_size}"
    data = _ops_get(url, tenant)
    if data and "content" in data:
        return data["content"]
    return []


# ---------------------------------------------------------------------------
# Polling
# ---------------------------------------------------------------------------
def wait_for_batch(domain, batch_id, tenant, timeout=300, poll_interval=5,
                   stall_timeout=90):
    """
    Smart polling — keeps waiting as long as progress is being made.

    Stops when:
      - ongoing == 0 (all transactions settled)
      - no change in successful count for `stall_timeout` seconds (stuck)
      - hard `timeout` seconds elapsed regardless

    Progress (successful count increasing) resets the stall timer, so a
    slow-but-moving Mojaloop batch won't be abandoned prematurely.
    """
    hard_deadline    = time.time() + timeout
    last_successful  = -1
    last_progress_at = time.time()
    last             = None

    while True:
        now     = time.time()
        summary = fetch_batch_summary(domain, batch_id, tenant)

        if summary is not None:
            last       = summary
            total      = summary.get("total",      0)
            ongoing    = summary.get("ongoing",    -1)
            successful = summary.get("successful", 0)

            # All done
            if total > 0 and ongoing == 0:
                return last

            # Progress made — reset stall timer
            if successful > last_successful:
                last_progress_at = now
                last_successful  = successful
                print(f"\r    progress: {successful}/{total} completed, {ongoing} ongoing …",
                      end="", flush=True)

        stalled    = (now - last_progress_at) > stall_timeout
        timed_out  = now >= hard_deadline

        if stalled or timed_out:
            reason = "stalled (no progress)" if stalled else f"hard timeout ({timeout}s)"
            print(f"\r    stopped waiting: {reason}                          ")
            break

        time.sleep(poll_interval)

    # One final check after breaking out
    final = fetch_batch_summary(domain, batch_id, tenant)
    return final if final is not None else last


# ---------------------------------------------------------------------------
# Display helpers
# ---------------------------------------------------------------------------
def print_sep(char="─", width=72):
    print(char * width)


def print_scenario_header(idx, scenario):
    print()
    print_sep("═")
    print(bold(f"  Scenario {idx}: {scenario['name']}"))
    print(f"  Tenant : {scenario['tenant']}")
    print(f"  CSV    : {scenario['csv'].name}")
    mode_desc = ("GovStack — identity validation + de-bulking by payee FSP"
                 if scenario["govstack"] else "Standard — payer from CSV, no identity validation")
    print(f"  Mode   : {mode_desc}")
    print_sep("═")


def print_batch_result(summary, elapsed):
    if summary is None:
        print(warn("  Could not retrieve batch summary from operations-app"))
        return

    total      = summary.get("total",      0)
    successful = summary.get("successful", 0)
    failed     = summary.get("failed",     0)
    ongoing    = summary.get("ongoing",    0)
    status     = summary.get("status",     "?")
    pct_ok     = summary.get("successPercentage", "?")
    payer_fsp  = summary.get("payerFsp", "?")
    reg_inst   = summary.get("registeringInstitutionId", "?")

    print(f"  Status           : {status}")
    print(f"  Total            : {total}")
    print(f"  Successful       : {successful}  ({pct_ok}%)")
    print(f"  Failed           : {failed}")
    print(f"  Ongoing          : {ongoing}")
    print(f"  Payer FSP        : {payer_fsp}")
    if reg_inst and reg_inst != "null":
        print(f"  Registering Inst : {reg_inst}")
    print(f"  Elapsed          : {elapsed:.1f}s")

    # Verdict
    all_done = (ongoing == 0)
    if all_done and successful == total and failed == 0 and total > 0:
        print(ok(f"  ALL {total} transactions PASSED"))
    elif all_done and failed > 0:
        print(fail(f"  {failed}/{total} transactions FAILED"))
    elif all_done and total == 0:
        print(warn("  Batch total=0 after timeout — transfers may not have started yet (try --timeout 240)"))
        print(warn("  For GovStack: identity mapper may have no data (run generate-mifos-vnext-data.py --regenerate)"))
    elif not all_done:
        print(warn(f"  {ongoing} transaction(s) still IN_PROGRESS after {elapsed:.0f}s"))
        print(warn(f"  Zeebe workflows may still be running — re-check with --check or increase --stall-timeout"))
    else:
        print(warn(f"  Unexpected state: status={status}"))


def print_transfers(transfers):
    if not transfers:
        return
    print(f"\n  {'Payee MSISDN':<16} {'Payee FSP':<14} {'Status':<14} {'Amount':>8}  Error")
    print(f"  {'─'*14:<16} {'─'*12:<14} {'─'*12:<14} {'─'*8:>8}  {'─'*20}")
    for t in transfers:
        payee   = t.get("payeePartyId")  or "?"
        dfsp    = t.get("payeeDfspId")   or "?"
        status  = t.get("status")        or "?"
        amount  = t.get("amount")        or "?"
        err     = t.get("errorInformation") or ""
        err_str = str(err)[:30] if err else ""
        line    = f"  {str(payee):<16} {str(dfsp):<14} {str(status):<14} {str(amount):>8}  {err_str}"
        if status == "COMPLETED":
            print(f"{GREEN}{line}{RESET}")
        elif status == "FAILED":
            print(f"{RED}{line}{RESET}")
        else:
            print(line)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Submit and verify all 4 non-Mastercard bulk batch scenarios",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Scenarios:
  1. Mojaloop  / Non-GovStack  --tenant greenbank
  2. Closedloop / Non-GovStack  --tenant redbank
  3. Mojaloop  / GovStack       --tenant greenbank --govstack
  4. Closedloop / GovStack       --tenant redbank   --govstack

Batch verification uses the operations-app REST API:
  GET https://ops.{domain}/api/v1/batch/{batchId}?command=aggregate
  GET https://ops.{domain}/api/v1/batch/detail?batchId={batchId}

Prerequisites for GovStack scenarios:
  identity-account-mapper must be populated — run:
    generate-mifos-vnext-data.py --regenerate
        """,
    )
    parser.add_argument("-c", "--config", type=Path, default=DEFAULT_CFG,
                        help=f"Path to config.ini (default: {DEFAULT_CFG})")
    parser.add_argument("--timeout", type=int, default=300,
                        help="Hard max seconds to wait per batch (default: 300)")
    parser.add_argument("--stall-timeout", type=int, default=90,
                        help="Stop waiting if no progress for this many seconds (default: 90)")
    parser.add_argument("--poll-interval", type=int, default=5,
                        help="Polling interval in seconds (default: 5)")
    parser.add_argument("--no-transfers", action="store_true",
                        help="Skip per-transfer detail output")
    args = parser.parse_args()

    if not args.config.exists():
        print(fail(f"Config file not found: {args.config}"))
        sys.exit(1)

    for csv_path in (MOJALOOP_CSV, CLOSEDLOOP_CSV):
        if not csv_path.exists():
            print(fail(f"CSV not found: {csv_path}"))
            print("  Run generate-example-csv-files.py first.")
            sys.exit(1)

    domain = load_domain(args.config)

    # -----------------------------------------------------------------------
    # Phase 1: submit all batches
    # -----------------------------------------------------------------------
    print()
    print(bold("=" * 72))
    print(bold("  BULK BATCH VERIFICATION — 4 scenarios"))
    print(bold("=" * 72))
    print(f"  Config : {args.config}")
    print(f"  Domain : {domain}")
    print(f"  Timeout: {args.timeout}s per batch")

    submissions = []

    for idx, scenario in enumerate(SCENARIOS, start=1):
        print_scenario_header(idx, scenario)
        print("  Submitting…", end="", flush=True)
        t0 = time.time()
        batch_id, stderr, rc = submit_batch(scenario, args.config)
        elapsed = time.time() - t0

        if rc == 0 and batch_id:
            print(f"\r  {ok(f'Submitted in {elapsed:.1f}s')}")
            print(f"  batch_id : {batch_id}")
        elif rc == 0 and not batch_id:
            print(f"\r  {warn('HTTP 2xx but no PollingPath/batch_id found in response')}")
            # Show last few lines to help debug
            tail = "\n    ".join(stderr.strip().splitlines()[-6:])
            print(f"    {tail}")
        else:
            print(f"\r  {fail('Submission FAILED')}")
            tail = "\n    ".join(stderr.strip().splitlines()[-10:])
            print(f"    {tail}")

        submissions.append({
            "scenario": scenario,
            "batch_id": batch_id,
            "submitted": rc == 0 and batch_id is not None,
        })

    # -----------------------------------------------------------------------
    # Phase 2: wait and verify via operations-app API
    # -----------------------------------------------------------------------
    print()
    print(bold("=" * 72))
    print(bold("  VERIFICATION via operations-app API"))
    print(bold("=" * 72))

    results = []

    for sub in submissions:
        scenario = sub["scenario"]
        batch_id = sub["batch_id"]
        print()
        print(info(f"  [{scenario['name']}]  batch_id={batch_id or 'N/A'}"))

        if not sub["submitted"]:
            print(warn("  Skipping — batch was not submitted successfully"))
            results.append({
                "name": scenario["name"], "submitted": False,
                "batch_id": None, "summary": None, "elapsed": 0,
            })
            continue

        print(f"  Polling (hard timeout={args.timeout}s, stall={args.stall_timeout}s)…")
        t0 = time.time()
        summary = wait_for_batch(
            domain, batch_id, scenario["tenant"],
            timeout=args.timeout, poll_interval=args.poll_interval,
            stall_timeout=args.stall_timeout,
        )
        elapsed = time.time() - t0
        print(f" done ({elapsed:.1f}s)")

        print_batch_result(summary, elapsed)

        if not args.no_transfers:
            transfers = fetch_batch_transfers(domain, batch_id, scenario["tenant"])
            print_transfers(transfers)

        results.append({
            "name": scenario["name"],
            "submitted": True,
            "batch_id": batch_id,
            "summary": summary,
            "elapsed": elapsed,
        })

    # -----------------------------------------------------------------------
    # Phase 3: summary table
    # -----------------------------------------------------------------------
    print()
    print(bold("=" * 72))
    print(bold("  SUMMARY"))
    print(bold("=" * 72))
    print(f"\n  {'Scenario':<35} {'Submitted':<10} {'Total':>5} {'OK':>5} {'Fail':>5} {'Active':>7}  Result")
    print(f"  {'─'*33:<35} {'─'*8:<10} {'─'*5:>5} {'─'*5:>5} {'─'*5:>5} {'─'*7:>7}  {'─'*6}")

    all_passed = True
    for r in results:
        s = r["summary"]
        sub_str = ok("yes") if r["submitted"] else fail("no")

        if not r["submitted"] or s is None:
            verdict = fail("NO DATA")
            all_passed = False
            total_s = ok_s = fail_s = act_s = "—"
        else:
            total_s = str(s.get("total",      0))
            ok_s    = str(s.get("successful", 0))
            fail_s  = str(s.get("failed",     0))
            act_s   = str(s.get("ongoing",    0))
            total   = s.get("total",      0)
            succ    = s.get("successful", 0)
            failed  = s.get("failed",     0)
            ongoing = s.get("ongoing",    0)
            passed  = (succ == total and failed == 0 and total > 0 and ongoing == 0)
            verdict = ok("PASS") if passed else fail("FAIL")
            if not passed:
                all_passed = False

        print(f"  {r['name']:<35} {sub_str:<18} {total_s:>5} {ok_s:>5} {fail_s:>5} {act_s:>7}  {verdict}")

    print()
    if all_passed:
        print(ok(bold("  ALL SCENARIOS PASSED")))
    else:
        print(fail(bold("  ONE OR MORE SCENARIOS FAILED — see details above")))
    print()


if __name__ == "__main__":
    main()
