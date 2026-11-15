"""Import the V1 Google Sheet into Supabase (FinanceTracker V2, phase 1).

Reads transactions, holdings and realized P&L through the existing Apps Script
web app, then writes them into the Supabase tables created by
supabase/migrations/20261114000000_init.sql.

Safe to re-run: rows are matched on their V1 id (legacy_id), so a second run
updates instead of duplicating.

Usage (from the project root):
    python scripts/import_sheet_to_supabase.py --owner-email you@example.com --household "Keluarga" --dry-run
    python scripts/import_sheet_to_supabase.py --owner-email you@example.com --household "Keluarga"

Needs in the root .env:
    APPS_SCRIPT_URL, API_SECRET          (the V1 backend)
    SUPABASE_URL, SUPABASE_SECRET_KEY    (secret / service_role key: server-side only)

The owner must already exist as a Supabase user (Authentication -> Users -> Add user).
"""
import argparse
import hashlib
import os
import sys
import uuid
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "TelegramBot"))
import env_loader  # noqa: E402,F401  (loads the root .env on import)

TX_TYPES = {"income", "expense", "invest", "transfer-out", "transfer-in"}
UNASSIGNED = {"", "unassigned"}
CHUNK = 500
TIMEOUT = 60


def need(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        sys.exit(f"Missing {name} in .env")
    return value


# ---------------------------------------------------------------- V1 sheet

def sheet_get(action: str):
    resp = requests.get(
        need("APPS_SCRIPT_URL"),
        params={"action": action, "secret": need("API_SECRET")},
        timeout=TIMEOUT,
    )
    resp.raise_for_status()
    body = resp.json()
    if not body.get("ok"):
        sys.exit(f"Apps Script '{action}' failed: {body.get('error')}")
    return body["data"]


# ---------------------------------------------------------------- Supabase

class Supabase:
    def __init__(self):
        self.url = need("SUPABASE_URL").rstrip("/")
        key = need("SUPABASE_SECRET_KEY")
        self.headers = {"apikey": key, "Authorization": f"Bearer {key}"}

    def _check(self, resp, what):
        if resp.status_code >= 400:
            sys.exit(f"Supabase {what} failed ({resp.status_code}): {resp.text[:400]}")
        return resp

    def select(self, table, **filters):
        resp = requests.get(f"{self.url}/rest/v1/{table}", headers=self.headers,
                            params={"select": "*", **filters}, timeout=TIMEOUT)
        return self._check(resp, f"select {table}").json()

    def insert(self, table, rows, on_conflict=None):
        """Insert rows; with on_conflict, update the existing row instead."""
        if not rows:
            return []
        prefer = "return=representation"
        params = {}
        if on_conflict:
            prefer += ",resolution=merge-duplicates"
            params["on_conflict"] = on_conflict
        out = []
        for i in range(0, len(rows), CHUNK):
            resp = requests.post(
                f"{self.url}/rest/v1/{table}", params=params, json=rows[i:i + CHUNK],
                headers={**self.headers, "Prefer": prefer}, timeout=TIMEOUT)
            out.extend(self._check(resp, f"insert {table}").json())
        return out

    def find_user_id(self, email):
        page = 1
        while True:
            resp = requests.get(f"{self.url}/auth/v1/admin/users", headers=self.headers,
                                params={"page": page, "per_page": 200}, timeout=TIMEOUT)
            users = self._check(resp, "list users").json().get("users", [])
            for user in users:
                if (user.get("email") or "").lower() == email.lower():
                    return user["id"]
            if len(users) < 200:
                return None
            page += 1


# ---------------------------------------------------------------- helpers

def clean_date(value):
    """'YYYY-MM-DD' or None (the column default then applies)."""
    text = str(value or "").strip()[:10]
    return text if len(text) == 10 and text[4] == "-" and text[7] == "-" else None


def is_unassigned(name) -> bool:
    return str(name or "").strip().lower() in UNASSIGNED


def transfer_group(legacy_id: str):
    """TRF-<pair>-OUT / TRF-<pair>-IN share one deterministic group id."""
    if not legacy_id.startswith("TRF-"):
        return None
    pair = legacy_id.rsplit("-", 1)[0]
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"financetracker:{pair}"))


def fingerprint(prefix: str, parts, seen: dict) -> str:
    """Stable id for V1 rows that have none (legacy holdings)."""
    digest = hashlib.sha1("|".join(str(p) for p in parts).encode()).hexdigest()[:12]
    seen[digest] = seen.get(digest, 0) + 1
    return f"{prefix}-LEGACY-{digest}-{seen[digest]}"


def same_keys(rows):
    """PostgREST bulk insert needs every object to carry the same keys."""
    keys = set().union(*(r.keys() for r in rows)) if rows else set()
    return [{k: r.get(k) for k in keys} for r in rows]


def ensure_named(db, table, household_id, names):
    """Get-or-create rows by case-insensitive name; return {lower_name: id}."""
    existing = {r["name"].lower(): r["id"]
                for r in db.select(table, household_id=f"eq.{household_id}")}
    missing, seen = [], set()
    for name in names:
        key = name.lower()
        if key not in existing and key not in seen:
            seen.add(key)
            missing.append({"household_id": household_id, "name": name})
    for row in db.insert(table, missing):
        existing[row["name"].lower()] = row["id"]
    return existing


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description="Import the V1 Google Sheet into Supabase.")
    ap.add_argument("--owner-email", required=True, help="existing Supabase user who will own the household")
    ap.add_argument("--household", required=True, help="household name (created if the owner has none with this name)")
    ap.add_argument("--dry-run", action="store_true", help="read the Sheet and report, write nothing")
    args = ap.parse_args()

    print("Reading the Google Sheet through Apps Script...")
    txns = sheet_get("read")
    holdings = sheet_get("holdings")
    realized = sheet_get("realized").get("rows", [])

    skipped = [t for t in txns if t.get("type") not in TX_TYPES]
    txns = [t for t in txns if t.get("type") in TX_TYPES]

    account_names = sorted({str(r.get("account")).strip() for r in txns + realized
                            if not is_unassigned(r.get("account"))}, key=str.lower)
    category_names = sorted({str(t.get("category") or "Other").strip() or "Other" for t in txns},
                            key=str.lower)

    print(f"  transactions: {len(txns)}  (skipped, unknown type: {len(skipped)})")
    print(f"  holdings:     {len(holdings)}")
    print(f"  realized:     {len(realized)}")
    print(f"  accounts:     {', '.join(account_names) or '(none)'}")
    print(f"  categories:   {len(category_names)}")

    if args.dry_run:
        print("Dry run: nothing written.")
        return

    db = Supabase()
    owner_id = db.find_user_id(args.owner_email)
    if not owner_id:
        sys.exit("No Supabase user with that email. Add the user in the dashboard first.")

    # household: reuse one the owner already belongs to with this name
    memberships = db.select("members", user_id=f"eq.{owner_id}")
    household_id = None
    for m in memberships:
        found = db.select("households", id=f"eq.{m['household_id']}")
        if found and found[0]["name"].lower() == args.household.lower():
            household_id = found[0]["id"]
            break
    if household_id:
        print(f"Using existing household '{args.household}'.")
    else:
        household_id = db.insert("households", [{"name": args.household, "created_by": owner_id}])[0]["id"]
        db.insert("members", [{"household_id": household_id, "user_id": owner_id, "role": "owner"}])
        print(f"Created household '{args.household}'.")

    accounts = ensure_named(db, "accounts", household_id, account_names)
    categories = ensure_named(db, "categories", household_id, category_names)

    def account_id(name):
        return None if is_unassigned(name) else accounts.get(str(name).strip().lower())

    tx_rows = []
    for t in txns:
        legacy = str(t.get("id") or "").strip()
        if not legacy:
            continue
        row = {
            "household_id": household_id,
            "legacy_id": legacy,
            "type": t["type"],
            "category_id": categories.get((str(t.get("category") or "Other").strip() or "Other").lower()),
            "description": str(t.get("description") or ""),
            "amount": abs(float(t.get("amount") or 0)),
            "source": str(t.get("source") or "web"),
            "account_id": account_id(t.get("account")),
            "transfer_group": transfer_group(legacy),
            "created_by": owner_id,
        }
        date = clean_date(t.get("date"))
        if date:
            row["date"] = date
        tx_rows.append(row)
    # rows without a readable date are sent separately so the column default applies
    dated = [r for r in tx_rows if "date" in r]
    undated = [r for r in tx_rows if "date" not in r]
    db.insert("transactions", same_keys(dated), on_conflict="household_id,legacy_id")
    db.insert("transactions", same_keys(undated), on_conflict="household_id,legacy_id")
    print(f"Transactions imported: {len(tx_rows)} ({len(undated)} without a date, set to today)")

    seen = {}
    holding_rows = []
    for h in holdings:
        qty = float(h.get("quantity") or 0)
        asset_type = str(h.get("assetType") or "").lower().strip()
        if qty <= 0 or asset_type not in ("gold", "stock"):
            continue
        legacy = str(h.get("id") or "").strip() or fingerprint(
            "HLD", [asset_type, h.get("ticker"), h.get("name"), qty, h.get("buyPrice"), h.get("buyDate")], seen)
        holding_rows.append({
            "household_id": household_id,
            "legacy_id": legacy,
            "asset_type": asset_type,
            "ticker": str(h.get("ticker") or "").upper().strip(),
            "name": str(h.get("name") or ""),
            "quantity": qty,
            "buy_price": float(h.get("buyPrice") or 0),
            "buy_date": clean_date(h.get("buyDate")),
        })
    db.insert("holdings", holding_rows, on_conflict="household_id,legacy_id")
    print(f"Holdings imported: {len(holding_rows)}")

    sale_rows = []
    for s in realized:
        legacy = str(s.get("id") or "").strip()
        date = clean_date(s.get("date"))
        if not legacy or not date:
            continue
        sale_rows.append({
            "household_id": household_id,
            "legacy_id": legacy,
            "date": date,
            "asset_type": str(s.get("assetType") or ""),
            "ticker": str(s.get("ticker") or ""),
            "name": str(s.get("name") or ""),
            "quantity": float(s.get("quantity") or 0),
            "avg_buy_price": float(s.get("avgBuyPrice") or 0),
            "sell_price": float(s.get("sellPrice") or 0),
            "proceeds": float(s.get("proceeds") or 0),
            "cost_basis": float(s.get("costBasis") or 0),
            "realized_pl": float(s.get("realizedPl") or 0),
            "account_id": account_id(s.get("account")),
        })
    db.insert("sales", sale_rows, on_conflict="household_id,legacy_id")
    print(f"Realized P&L rows imported: {len(sale_rows)}")

    # check: compare per-account balances with the Sheet
    sheet_bal = sheet_get("accounts").get("balances", {})
    supa_bal = {r["name"].lower(): float(r["balance"])
                for r in db.select("account_balances", household_id=f"eq.{household_id}")}
    print("Balance check (Sheet vs Supabase):")
    ok = True
    for name, value in sorted(sheet_bal.items()):
        if is_unassigned(name):
            continue
        got = supa_bal.get(name.lower())
        match = got is not None and abs(got - float(value)) < 0.01
        ok = ok and match
        print(f"  {'OK ' if match else 'DIFF'} {name}: sheet {float(value):,.0f} / supabase "
              f"{'missing' if got is None else f'{got:,.0f}'}")
    print("Import complete." if ok else "Import finished with balance differences: check the rows above.")


if __name__ == "__main__":
    main()
