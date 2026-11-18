#!/usr/bin/env python3
"""Sync deadlyartofsurvival.com votes into daosmedia.com (Jake, Nov 18, 2026:
"The votes based off deadlyartofsurvival.com — should be updated
automatically on the Daosmedia website").

How: every Shopify customer carrying a VOTE_<FIGHTER> tag is a vote cast
on the Shopify vote pages. Each one is replayed into Supabase through the
SAME public cast_fighter_vote() RPC the website itself uses (anon key),
so the fighter_votes trigger bumps fighter_profiles.votes_count and the
daosmedia Rankings leaderboard matches the Shopify board.

Dedupe is enforced by the database itself (unique fighter+email and
fighter+phone), so re-running is safe: repeat votes come back as
"already voted" errors and are counted as duplicates, never double votes.
App votes that were synced TO Shopify as tagged customers likewise come
back as duplicates — both boards converge on the same totals.

A voter needs BOTH an email and a phone to enter through the RPC (the
one-vote-per-phone rule); tagged customers missing either are reported
as skipped, never invented.
"""
import json, subprocess, sys, time, urllib.request, urllib.error

SUPABASE_URL = "https://hsgbmrtpwnyqkmfnveaz.supabase.co"
ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhzZ2JtcnRwd255cWttZm52ZWF6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTM4NDQ4NTcsImV4cCI6MjEwOTQyMDg1N30.UMb6rqV35IM16_Tu8HLDrrct0DNaDZdtIi29FsMe6fA"

FIGHTERS = [
    ("VOTE_JORGE_BORJAS", "jorge-borjas"),
    ("VOTE_AKER_RAMESSU_IYI", "aker-ramessu-iyi"),
    ("VOTE_JAMIE", "jamie"),
    ("VOTE_STACEY_LEGG", "stacey-legg"),
    ("VOTE_SENDO_TRAN", "sendo-tran"),
    ("VOTE_JAIDEN_GRACIANI", "jaiden-graciani"),
    ("VOTE_CHRIS_MALARKEY", "chris-malarkey"),
]

def gql(query):
    args = {"query": query}
    last_err = None
    for attempt in range(4):
        r = subprocess.run(["shopify", "call-tool", "--name", "graphql_query",
                            "--arguments-json", json.dumps(args)],
                           capture_output=True, text=True, timeout=120)
        try:
            return json.loads(r.stdout)["result"]["structuredContent"]["data"]
        except (json.JSONDecodeError, KeyError) as e:
            last_err = e
            time.sleep(15 * (attempt + 1))
    print(f"ERROR: shopify query failed: {last_err}", file=sys.stderr)
    sys.exit(1)

def tagged_customers(tag):
    out, cursor = [], None
    while True:
        after = f', after: "{cursor}"' if cursor else ""
        d = gql(f'{{ customers(first: 100{after}, query: "tag:{tag}") '
                f'{{ edges {{ node {{ id defaultEmailAddress {{ emailAddress }} '
                f'defaultPhoneNumber {{ phoneNumber }} }} }} '
                f'pageInfo {{ hasNextPage endCursor }} }} }}')
        conn = d["customers"]
        for e in conn["edges"]:
            n = e["node"]
            email = (n.get("defaultEmailAddress") or {}).get("emailAddress")
            phone = (n.get("defaultPhoneNumber") or {}).get("phoneNumber")
            out.append((email, phone))
        if not conn["pageInfo"]["hasNextPage"]:
            return out
        cursor = conn["pageInfo"]["endCursor"]

def sb(path, method="GET", body=None):
    req = urllib.request.Request(SUPABASE_URL + path, method=method)
    req.add_header("apikey", ANON_KEY)
    req.add_header("Authorization", "Bearer " + ANON_KEY)
    data = None
    if body is not None:
        req.add_header("Content-Type", "application/json")
        data = json.dumps(body).encode()
    try:
        with urllib.request.urlopen(req, data=data, timeout=60) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, {"message": raw}

def main():
    status, fighters = sb("/rest/v1/fighter_profiles?select=id,slug,votes_count&status=eq.live")
    if status != 200:
        print(f"ERROR: could not read fighter_profiles: {status} {fighters}", file=sys.stderr)
        sys.exit(1)
    by_slug = {f["slug"]: f for f in fighters}
    summary = {}
    for tag, slug in FIGHTERS:
        prof = by_slug.get(slug)
        if not prof:
            summary[slug] = {"error": "no live fighter_profile for slug"}
            continue
        voters = tagged_customers(tag)
        inserted = dup = skipped = errors = 0
        err_msgs = []
        for email, phone in voters:
            if not email or not phone:
                skipped += 1
                continue
            code, resp = sb("/rest/v1/rpc/cast_fighter_vote", method="POST",
                            body={"p_fighter_id": prof["id"],
                                  "p_voter_email": email,
                                  "p_voter_phone": phone})
            if code in (200, 201, 204):
                inserted += 1
            else:
                msg = (resp or {}).get("message", "") if isinstance(resp, dict) else str(resp)
                if "already" in msg.lower():
                    dup += 1
                else:
                    errors += 1
                    err_msgs.append(msg[:160])
        summary[slug] = {"shopify_tagged": len(voters), "inserted": inserted,
                         "duplicates": dup, "skipped_no_email_or_phone": skipped,
                         "errors": errors, "error_messages": err_msgs[:3]}
    status, after = sb("/rest/v1/fighter_profiles?select=slug,votes_count&status=eq.live&order=votes_count.desc")
    summary["_daosmedia_counts_after"] = {f["slug"]: f["votes_count"] for f in after} if status == 200 else {}
    print(json.dumps(summary, indent=1))

if __name__ == "__main__":
    main()
