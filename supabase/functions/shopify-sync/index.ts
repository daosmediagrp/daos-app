// shopify-sync — DAOS app members → Shopify customers (Jake, Nov 19, 2026).
//
// What it does: reads app profiles (Supabase) and creates/updates the
// matching Shopify customer, tagged 'daos-app', carrying the member's
// email + phone. Marketing consent is set ONLY where the member
// explicitly opted in at sign-up (timestamped on the profile):
//   email_opt_in → emailMarketingConsent SUBSCRIBED
//   sms_opt_in   → smsMarketingConsent SUBSCRIBED
// Members who did not opt in sync as plain customer records with NO
// marketing consent — they cannot be blasted. This function only ever
// touches app sign-ups; no external lists are imported here.
//
// Trigger: POST with header x-sync-secret matching the SYNC_SECRET
// secret (staff tooling / scheduled call). Body may carry
// { "user_id": "<uuid>" } to sync one member; no body = sync all
// profiles not yet synced or changed since their last sync.
//
// Secrets needed (Supabase → Edge Functions → Secrets):
//   SHOPIFY_SHOP_DOMAIN   e.g. deadlyartofsurvival.myshopify.com
//   SHOPIFY_ADMIN_TOKEN   custom app Admin API token (Jake creates it
//                         in Shopify Settings → Apps and sales
//                         channels → Develop apps; scopes:
//                         write_customers)
//   SYNC_SECRET           any long random string, caller's header
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are provided automatically.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SHOP = Deno.env.get("SHOPIFY_SHOP_DOMAIN") || "";
const TOKEN = Deno.env.get("SHOPIFY_ADMIN_TOKEN") || "";
const SYNC_SECRET = Deno.env.get("SYNC_SECRET") || "";
const API_VERSION = "2026-10";

async function shopifyGraphQL(query: string, variables: Record<string, unknown>) {
  const res = await fetch(`https://${SHOP}/admin/api/${API_VERSION}/graphql.json`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Shopify-Access-Token": TOKEN,
    },
    body: JSON.stringify({ query, variables }),
  });
  const json = await res.json();
  if (!res.ok || json.errors) {
    throw new Error("Shopify GraphQL: " + JSON.stringify(json.errors || res.status));
  }
  return json.data;
}

async function findCustomerByEmail(email: string): Promise<string | null> {
  const data = await shopifyGraphQL(
    `query($q: String!) { customers(first: 1, query: $q) { edges { node { id } } } }`,
    { q: `email:${email}` },
  );
  const edges = data?.customers?.edges || [];
  return edges.length ? edges[0].node.id : null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });
  if (!SYNC_SECRET || req.headers.get("x-sync-secret") !== SYNC_SECRET) {
    return new Response("Unauthorized", { status: 401 });
  }
  if (!SHOP || !TOKEN) {
    return new Response("Shopify secrets not set", { status: 500 });
  }

  let onlyUser = "";
  try {
    const body = await req.json();
    onlyUser = String(body?.user_id || "");
  } catch (_) { /* no body = sync all */ }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // Member emails live on auth.users; pull them via the admin API in
  // pages and join to profiles in memory (app scale is small).
  const emailById = new Map<string, string>();
  for (let page = 1; page <= 20; page++) {
    const { data, error } = await supabase.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) throw error;
    for (const u of data.users) if (u.email) emailById.set(u.id, u.email);
    if (data.users.length < 1000) break;
  }

  const cols = "id,display_name,phone,email_opt_in,email_opt_in_at,sms_opt_in,sms_opt_in_at,shopify_customer_id,shopify_synced_at";
  let q = supabase.from("profiles").select(cols + ",updated_at");
  if (onlyUser) q = q.eq("id", onlyUser);
  let { data: profiles, error } = await q;
  if (error) {
    // profiles may not have updated_at — retry without the
    // unchanged-skip optimization column.
    let q2 = supabase.from("profiles").select(cols);
    if (onlyUser) q2 = q2.eq("id", onlyUser);
    const retry = await q2;
    profiles = retry.data;
    error = retry.error;
  }
  if (error) throw error;

  let synced = 0, skipped = 0, failed = 0;
  for (const p of profiles || []) {
    const email = emailById.get(p.id);
    if (!email) { skipped++; continue; }
    // Skip unchanged members on full runs.
    if (!onlyUser && p.shopify_synced_at && p.updated_at &&
        new Date(p.shopify_synced_at) >= new Date(p.updated_at)) { skipped++; continue; }
    try {
      let customerId = p.shopify_customer_id || await findCustomerByEmail(email);
      const input: Record<string, unknown> = {
        email,
        firstName: (p.display_name || "").split(" ")[0] || undefined,
        lastName: (p.display_name || "").split(" ").slice(1).join(" ") || undefined,
        phone: p.phone || undefined,
        tags: ["daos-app"],
      };
      if (p.email_opt_in) {
        input.emailMarketingConsent = {
          marketingState: "SUBSCRIBED",
          marketingOptInLevel: "SINGLE_OPT_IN",
          consentUpdatedAt: p.email_opt_in_at || new Date().toISOString(),
        };
      }
      if (p.sms_opt_in && p.phone) {
        input.smsMarketingConsent = {
          marketingState: "SUBSCRIBED",
          marketingOptInLevel: "SINGLE_OPT_IN",
          consentUpdatedAt: p.sms_opt_in_at || new Date().toISOString(),
          countryCode: "US",
        };
      }
      if (customerId) {
        input.id = customerId;
        const data = await shopifyGraphQL(
          `mutation($input: CustomerInput!) { customerUpdate(input: $input) {
             customer { id } userErrors { field message } } }`,
          { input },
        );
        const errs = data?.customerUpdate?.userErrors || [];
        if (errs.length) throw new Error(JSON.stringify(errs));
      } else {
        const data = await shopifyGraphQL(
          `mutation($input: CustomerInput!) { customerCreate(input: $input) {
             customer { id } userErrors { field message } } }`,
          { input },
        );
        const errs = data?.customerCreate?.userErrors || [];
        if (errs.length) throw new Error(JSON.stringify(errs));
        customerId = data?.customerCreate?.customer?.id || null;
      }
      await supabase.from("profiles").update({
        shopify_customer_id: customerId,
        shopify_synced_at: new Date().toISOString(),
      }).eq("id", p.id);
      synced++;
    } catch (e) {
      console.error("sync failed for", p.id, String(e));
      failed++;
    }
  }

  return new Response(JSON.stringify({ synced, skipped, failed }), {
    headers: { "Content-Type": "application/json" },
  });
});
