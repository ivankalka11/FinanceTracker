"""Run on the machine where your bot runs:  python diagnose_gold.py
Loads EMAS_API_KEY from the project-root .env (or the real environment)."""
import env_loader  # noqa: F401
import os
import requests
import pricing

print("1) EMAS_API_KEY set?",
      "yes" if pricing.EMAS_API_KEY else "NO — register at https://emas.maulanar.my.id/register")

if pricing.EMAS_API_KEY:
    try:
        r = requests.get(pricing.EMAS_API_BASE,
                         params={"brand": "ANTAM",
                                 "resource": "antam", "weight": "1"},
                         headers={**pricing.UA, "X-API-Key": pricing.EMAS_API_KEY}, timeout=20)
        print("   HTTP", r.status_code)
        print("   raw:", r.text[:400])
    except Exception as e:
        print("   ERROR", e)

print("2) get_gold_buyback():", pricing.get_gold_buyback())
