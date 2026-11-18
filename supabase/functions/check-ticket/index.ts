// ===========================================================================
// check-ticket — Supabase Edge Function (Deno).
//
// DAOS Party door check-in (Dec 5, 2026, Row House, Harlem) + the
// DAOS Card QR <-> Shopify tickets spec (Nov 18, 2026,
// goals/daos-iphone-app/files/daos-card-qr-shopify-tickets-spec.md).
// Shopify is the source of truth: this function only READS Shopify's
// answer, live, at scan time. Nothing about who paid is decided here.
//
// v2 (Nov 18, 2026) adds, over the Nov 8 v1:
//   * OWNER ticket view — a member looking at their OWN card now gets
//     their own ticket block (PAID / checked in), not just staff.
//     Check-in stays staff-only.
//   * CLAIM by order number — a logged-in member whose app email does
//     not match their checkout email can claim the ticket with the
//     order number. The order is verified LIVE in Shopify (paid, not
//     cancelled, Party product) and recorded in public.ticket_claims;
//     an order already claimed by another member is rejected. Lookups
//     check claims first, then fall back to the email match.
//   * orders/paid WEBHOOK cache — requests carrying an
//     X-Shopify-Hmac-Sha256 header are treated as Shopify webhooks:
//     the HMAC is verified against SHOPIFY_WEBHOOK_SECRET and Party
//     orders are upserted into public.ticket_orders. Lookups read the
//     cache ONLY when the live Shopify call fails (door resilience);
//     the ticket block then carries cached: true.
//
// ACTIONS (POST JSON body, Authorization: Bearer <user JWT>):
//   { action: "lookup",  token: "<card uuid>" }   // or { code: "A1B2-C3D4" }
//   { action: "checkin", token: "<card uuid>" }   // or { code: "A1B2-C3D4" }
//   { action: "claim",   order_number: "2807" }   // caller's own claim
//
// PRIVACY / SECURITY — read this before changing anything:
//   * The PUBLIC response (any caller, including logged-out) contains
//     ONLY the public profile: display name, photo, bio, and fighter
//     votes if the member has a live fighter profile. It NEVER
//     contains an email, a phone number, or ticket info.
//   * Ticket status is returned ONLY to (a) STAFF callers (valid JWT +
//     profiles.is_staff) looking at any card, or (b) the card's OWNER
//     looking at their own card. Everyone else gets the public
//     profile only — the response simply has no `ticket` field.
//   * The "checkin" action requires staff (403 otherwise), and
//     refuses to check in a non-ticket holder ("No ticket — sell at
//     door"). Check-ins are written with the service role and enforced
//     one-time by the UNIQUE (profile_id, event) constraint on
//     public.check_ins — a second attempt returns
//     { already_checked_in: true, checked_in_at: "..." }.
//   * Ticket lookup is LIVE against Shopify on every call — there is
//     no cached has_ticket flag. The member's email is resolved
//     server-side via supabase.auth.admin.getUserById (the site never
//     sees it), then Shopify orders are searched by that email (or by
//     the claimed order) and line items matched to the Party product.
//     The ticket_orders cache is a failure fallback only.
//   * Webhooks are trusted ONLY after HMAC verification — an unsigned
//     or badly signed request is rejected with 401.
//
// PARTY PRODUCT (resolved live via the Shopify MCP, Nov 8, 2026):
//   Product: "DAOS Party: The Best of The Best", handle "daos-party",
//     gid://shopify/Product/8851934347426, ACTIVE
//   Variant: "Default Title", $20.00,
//     gid://shopify/ProductVariant/46346830971042
//   Matching prefers the product / variant GIDs above. Fallback: a
//   line-item product whose title contains "DAOS Party" (case
//   insensitive) also counts, so a re-created Party product still
//   matches. Only non-cancelled orders with financialStatus PAID or
//   PARTIALLY_PAID count as a ticket.
//
// SECRETS (set in the Supabase dashboard > Edge Functions > Secrets —
// never hardcode them here):
//   SUPABASE_URL               e.g. https://hsgbmrtpwnyqkmfnveaz.supabase.co
//   SUPABASE_ANON_KEY          public anon key (used only to verify the
//                              caller's JWT)
//   SUPABASE_SERVICE_ROLE_KEY  service_role key (bypasses RLS; the only
//                              key that can read a member's auth email
//                              and write to check_ins / ticket_claims /
//                              ticket_orders, which have no write
//                              policies at all)
//   SHOPIFY_ADMIN_TOKEN        Admin API access token from the Shopify
//                              custom app (already set — same secret
//                              sync-votes-to-shopify uses)
//   SHOPIFY_STORE              myshopify.com domain, e.g.
//                              deadlyartofsurvival-com.myshopify.com
//                              (already set — same secret as above)
//   SHOPIFY_WEBHOOK_SECRET     the Shopify custom app's API secret key
//                              (used to verify orders/paid webhooks)
//
// CORS: the function is called from the browser (daosmedia.com / the
// iOS app WebView), so it answers OPTIONS preflights and sends
// Access-Control-Allow-Origin on every response.
//
// Returns JSON, e.g.:
//   Public: { profile: { id, display_name, bio, avatar_url,
//             fighter: { slug, display_name, votes_count } | null } }
//   Staff/owner: { profile: {...}, ticket: { has_ticket, ticket_type,
//             order_name, order_date, already_checked_in,
//             checked_in_at, cached? } }
//   Check-in success: { ..., ticket: {...}, checked_in: true,
//             checked_in_at: "..." }
//   Claim success: { claimed: true, order_name, ticket: {...} }
//   Errors: { error: "..." } with 400 / 401 / 403 / 404 / 500.
// ===========================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SHOPIFY_API_VERSION = "2025-10";
const EVENT = "daos-party-2026-12-05";
const PARTY_PRODUCT_ID = "gid://shopify/Product/8851934347426";
const PARTY_VARIANT_ID = "gid://shopify/ProductVariant/46346830971042";
const PARTY_PRODUCT_NUMERIC_ID = 8851934347426;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function json(body: Record<string, unknown>, status: number): Response {
  return Response.json(body, { status, headers: corsHeaders });
}

type ProfileRow = {
  id: string;
  display_name: string;
  bio: string | null;
  avatar_url: string | null;
  card_token: string;
  card_code: string | null;
};

type FighterRow = {
  slug: string;
  display_name: string;
  votes_count: number;
};

function normalizeCode(raw: string): string | null {
  const hex = raw.replace(/[^A-Za-z0-9]/g, "").toUpperCase();
  if (hex.length !== 8) return null;
  return hex.slice(0, 4) + "-" + hex.slice(4, 8);
}

function isUuid(value: string): boolean {
  return /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(value);
}

function esc(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

async function shopifyGraphQL(
  store: string,
  token: string,
  query: string,
  variables: Record<string, unknown>,
): Promise<Record<string, any>> {
  const res = await fetch(
    `https://${store}/admin/api/${SHOPIFY_API_VERSION}/graphql.json`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Shopify-Access-Token": token,
      },
      body: JSON.stringify({ query, variables }),
    },
  );
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`Shopify HTTP ${res.status}: ${text.slice(0, 300)}`);
  }
  const data = await res.json();
  if (data.errors?.length) {
    throw new Error(
      `Shopify GraphQL error: ${
        data.errors.map((e: { message: string }) => e.message).join("; ")
      }`,
    );
  }
  return data.data;
}

const ORDER_FIELDS = `
  id name createdAt cancelledAt financialStatus
  lineItems(first: 20) {
    edges {
      node {
        title quantity
        product { id title }
        variant { id title }
      }
    }
  }
`;

const FIND_ORDERS_BY_EMAIL = `
  query ordersByEmail($query: String!) {
    orders(first: 10, query: $query) {
      edges { node { ${ORDER_FIELDS} } }
    }
  }
`;

const FIND_ORDERS_BY_NAME = `
  query ordersByName($query: String!) {
    orders(first: 5, query: $query) {
      edges { node { ${ORDER_FIELDS} } }
    }
  }
`;

const GET_ORDER = `
  query orderById($id: ID!) {
    order(id: $id) { ${ORDER_FIELDS} }
  }
`;

type TicketResult = {
  has_ticket: boolean;
  ticket_type: string | null;
  order_name: string | null;
  order_date: string | null;
  cached?: boolean;
};

const NO_TICKET: TicketResult = {
  has_ticket: false,
  ticket_type: null,
  order_name: null,
  order_date: null,
};

// Does this (GraphQL-shaped) order carry a valid Party ticket?
// Returns the ticket block for the order, or null.
function ticketFromOrder(order: Record<string, any>): TicketResult | null {
  if (!order || order.cancelledAt) return null;
  if (!["PAID", "PARTIALLY_PAID"].includes(order.financialStatus)) {
    return null;
  }
  const items = (order.lineItems?.edges ?? [])
    .map((e: { node: Record<string, any> }) => e.node);
  for (const item of items) {
    const productId = item.product?.id as string | undefined;
    const variantId = item.variant?.id as string | undefined;
    const productTitle = String(item.product?.title ?? "");
    const isParty =
      productId === PARTY_PRODUCT_ID ||
      variantId === PARTY_VARIANT_ID ||
      /DAOS Party/i.test(productTitle);
    if (!isParty) continue;
    const variantTitle = String(item.variant?.title ?? "");
    return {
      has_ticket: true,
      ticket_type:
        variantTitle && variantTitle !== "Default Title"
          ? variantTitle
          : productTitle || item.title,
      order_name: order.name ?? null,
      order_date: order.createdAt ?? null,
    };
  }
  return null;
}

// Live Shopify lookup by buyer email: most recent paid Party order wins.
async function findPartyTicketByEmail(
  store: string,
  token: string,
  email: string,
): Promise<TicketResult> {
  const data = await shopifyGraphQL(store, token, FIND_ORDERS_BY_EMAIL, {
    query: `email:${esc(email)}`,
  });
  const orders = (data?.orders?.edges ?? [])
    .map((e: { node: Record<string, any> }) => e.node)
    .sort((a: Record<string, any>, b: Record<string, any>) =>
      String(b.createdAt).localeCompare(String(a.createdAt))
    );
  for (const order of orders) {
    const t = ticketFromOrder(order);
    if (t) return t;
  }
  return NO_TICKET;
}

// Live Shopify lookup of one order by its GID (used for claimed orders).
async function findPartyTicketByOrderId(
  store: string,
  token: string,
  orderId: string,
): Promise<TicketResult> {
  const data = await shopifyGraphQL(store, token, GET_ORDER, { id: orderId });
  return ticketFromOrder(data?.order) ?? NO_TICKET;
}

// Verify a Shopify webhook's HMAC-SHA256 (base64) against the app secret.
async function verifyWebhookHmac(
  rawBody: string,
  hmacHeader: string,
  secret: string,
): Promise<boolean> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(rawBody));
  const b64 = btoa(String.fromCharCode(...new Uint8Array(sig)));
  if (b64.length !== hmacHeader.length) return false;
  let diff = 0;
  for (let i = 0; i < b64.length; i++) {
    diff |= b64.charCodeAt(i) ^ hmacHeader.charCodeAt(i);
  }
  return diff === 0;
}

Deno.serve(async (req) => {
  // Browser preflight (the site calls this with an Authorization header).
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const shopifyToken = Deno.env.get("SHOPIFY_ADMIN_TOKEN");
  const shopifyStore = Deno.env.get("SHOPIFY_STORE");
  if (
    !supabaseUrl || !anonKey || !serviceRoleKey || !shopifyToken ||
    !shopifyStore
  ) {
    return json(
      {
        error:
          "Missing required env vars: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, SHOPIFY_ADMIN_TOKEN, SHOPIFY_STORE",
      },
      500,
    );
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  // ------------------------------------------------------------------
  // Shopify webhook branch (orders/paid). Webhooks do not carry our
  // JSON action shape — they are detected by the HMAC header, verified,
  // and Party orders are upserted into the ticket_orders cache.
  // ------------------------------------------------------------------
  const hmacHeader = req.headers.get("x-shopify-hmac-sha256");
  if (hmacHeader) {
    const webhookSecret = Deno.env.get("SHOPIFY_WEBHOOK_SECRET");
    if (!webhookSecret) {
      return json({ error: "SHOPIFY_WEBHOOK_SECRET is not set." }, 500);
    }
    const rawBody = await req.text();
    const ok = await verifyWebhookHmac(rawBody, hmacHeader, webhookSecret);
    if (!ok) return json({ error: "Invalid webhook signature." }, 401);
    let order: Record<string, any>;
    try {
      order = JSON.parse(rawBody);
    } catch (_e) {
      return json({ error: "Webhook body must be JSON." }, 400);
    }
    const items = Array.isArray(order.line_items) ? order.line_items : [];
    const isParty = items.some((li: Record<string, any>) =>
      li.product_id === PARTY_PRODUCT_NUMERIC_ID ||
      /DAOS Party/i.test(String(li.title ?? ""))
    );
    if (isParty && order.id) {
      const cust = order.customer ?? {};
      const buyerName = [cust.first_name, cust.last_name]
        .filter(Boolean).join(" ") || null;
      const { error: upsertError } = await admin
        .from("ticket_orders")
        .upsert({
          shopify_order_id: `gid://shopify/Order/${order.id}`,
          order_number: order.name ?? null,
          email: order.email ?? null,
          buyer_name: buyerName,
          event: EVENT,
          amount: order.total_price ? Number(order.total_price) : null,
          status: order.cancelled_at
            ? "CANCELLED"
            : String(order.financial_status ?? "").toUpperCase(),
          paid_at: order.created_at ?? null,
          updated_at: new Date().toISOString(),
        });
      if (upsertError) {
        return json(
          { error: `Could not cache order: ${upsertError.message}` },
          500,
        );
      }
    }
    return json({ ok: true }, 200);
  }

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch (_e) {
    return json({ error: "Request body must be JSON." }, 400);
  }
  const action = body.action === "checkin"
    ? "checkin"
    : body.action === "claim"
    ? "claim"
    : "lookup";

  // Resolve the caller (any logged-in user) once: JWT -> user id, then
  // the staff flag via the service role.
  let callerId: string | null = null;
  let isStaff = false;
  const authHeader = req.headers.get("Authorization");
  if (authHeader?.startsWith("Bearer ")) {
    const jwt = authHeader.slice("Bearer ".length).trim();
    if (jwt) {
      const authed = createClient(supabaseUrl, anonKey, {
        auth: { persistSession: false },
        global: { headers: { Authorization: authHeader } },
      });
      const { data: { user } } = await authed.auth.getUser(jwt);
      if (user) {
        callerId = user.id;
        const { data: staffRow } = await admin
          .from("profiles")
          .select("is_staff")
          .eq("id", user.id)
          .maybeSingle();
        if (staffRow && (staffRow as { is_staff: boolean }).is_staff) {
          isStaff = true;
        }
      }
    }
  }

  // ------------------------------------------------------------------
  // CLAIM action — the caller claims their own ticket by order number.
  // No card token needed: the claim attaches to the CALLER's profile.
  // ------------------------------------------------------------------
  if (action === "claim") {
    if (!callerId) {
      return json({ error: "Log in first, then claim your ticket." }, 401);
    }
    const rawNumber = typeof body.order_number === "string"
      ? body.order_number
      : "";
    const digits = rawNumber.replace(/[^0-9]/g, "");
    if (digits.length < 3 || digits.length > 7) {
      return json(
        { error: "Enter the order number from your Shopify receipt (digits only, e.g. 2807)." },
        200,
      );
    }
    const wantName = `#${digits}`;
    let order: Record<string, any> | null = null;
    try {
      const data = await shopifyGraphQL(shopifyStore, shopifyToken, FIND_ORDERS_BY_NAME, {
        query: `name:${digits}`,
      });
      const nodes = (data?.orders?.edges ?? [])
        .map((e: { node: Record<string, any> }) => e.node);
      order = nodes.find((o: Record<string, any>) => o.name === wantName) ??
        null;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      return json({ error: `Could not verify that order: ${msg}` }, 502);
    }
    if (!order) {
      return json(
        { error: `Order ${wantName} was not found. Check the number on your receipt.` },
        200,
      );
    }
    const ticket = ticketFromOrder(order);
    if (!ticket) {
      return json(
        { error: `Order ${wantName} does not hold a paid DAOS Party ticket.` },
        200,
      );
    }
    // One claim per order. Already the caller's? Say so, succeed.
    const { data: existingClaim } = await admin
      .from("ticket_claims")
      .select("profile_id")
      .eq("shopify_order_id", order.id)
      .maybeSingle();
    if (existingClaim) {
      if ((existingClaim as { profile_id: string }).profile_id !== callerId) {
        return json(
          { error: "That order is already claimed on another DAOS Card. If it is yours, contact daos@deadlyartofsurvival.com." },
          200,
        );
      }
      return json({ claimed: true, order_name: order.name, ticket }, 200);
    }
    const { error: claimError } = await admin
      .from("ticket_claims")
      .insert({
        profile_id: callerId,
        shopify_order_id: order.id,
        order_number: order.name,
        event: EVENT,
      });
    if (claimError) {
      if ((claimError as { code?: string }).code === "23505") {
        return json(
          { error: "That order is already claimed on another DAOS Card. If it is yours, contact daos@deadlyartofsurvival.com." },
          200,
        );
      }
      return json(
        { error: `Could not save the claim: ${claimError.message}` },
        500,
      );
    }
    return json({ claimed: true, order_name: order.name, ticket }, 200);
  }

  // ------------------------------------------------------------------
  // LOOKUP / CHECKIN — resolve the card first.
  // ------------------------------------------------------------------
  const tokenRaw = typeof body.token === "string" ? body.token.trim() : "";
  const codeRaw = typeof body.code === "string" ? body.code.trim() : "";
  const token = isUuid(tokenRaw) ? tokenRaw.toLowerCase() : null;
  const code = codeRaw ? normalizeCode(codeRaw) : null;
  if (!token && !code) {
    return json(
      { error: "Give a card token or a short code (e.g. A1B2-C3D4)." },
      400,
    );
  }

  // Resolve the card to a profile (service role: card_token / card_code
  // are the lookup keys). A miss is a plain 404 — tokens are random
  // uuids, so there is nothing to enumerate.
  const query = admin
    .from("profiles")
    .select("id,display_name,bio,avatar_url,card_token,card_code");
  const { data: profile, error: profileError } = token
    ? await query.eq("card_token", token).maybeSingle()
    : await query.eq("card_code", code).maybeSingle();
  if (profileError) {
    return json({ error: `Could not look up this card: ${profileError.message}` }, 500);
  }
  if (!profile) {
    return json({ error: "Card not found." }, 404);
  }
  const p = profile as ProfileRow;

  // Public profile — the ONLY thing an unrelated caller ever sees.
  // No email, no phone, no ticket info.
  const { data: fighter } = await admin
    .from("fighter_profiles")
    .select("slug,display_name,votes_count")
    .eq("user_id", p.id)
    .eq("status", "live")
    .maybeSingle();
  const publicProfile: Record<string, unknown> = {
    id: p.id,
    display_name: p.display_name,
    bio: p.bio,
    avatar_url: p.avatar_url,
    fighter: fighter
      ? {
        slug: (fighter as FighterRow).slug,
        display_name: (fighter as FighterRow).display_name,
        votes_count: (fighter as FighterRow).votes_count,
      }
      : null,
  };

  const isOwner = !!callerId && callerId === p.id;

  // Unrelated callers stop here: public profile only, no ticket field.
  if (!isStaff && !isOwner) {
    if (action === "checkin") {
      return json(
        { error: "Not authorized — door check-in is for DAOS staff only." },
        403,
      );
    }
    return json({ profile: publicProfile }, 200);
  }
  if (action === "checkin" && !isStaff) {
    return json(
      { error: "Not authorized — door check-in is for DAOS staff only." },
      403,
    );
  }

  // Ticket resolution. Claims first (they fix the email-mismatch case),
  // then the buyer's email. Both are LIVE Shopify reads. If Shopify
  // itself errors, fall back to the webhook cache and mark the block
  // cached: true so staff know it is the backup answer.
  let ticket: TicketResult;
  try {
    const { data: claim } = await admin
      .from("ticket_claims")
      .select("shopify_order_id")
      .eq("profile_id", p.id)
      .eq("event", EVENT)
      .maybeSingle();
    if (claim) {
      ticket = await findPartyTicketByOrderId(
        shopifyStore,
        shopifyToken,
        (claim as { shopify_order_id: string }).shopify_order_id,
      );
    } else {
      const { data: { user: cardUser }, error: userError } =
        await admin.auth.admin.getUserById(p.id);
      if (userError || !cardUser?.email) {
        ticket = NO_TICKET;
      } else {
        ticket = await findPartyTicketByEmail(
          shopifyStore,
          shopifyToken,
          cardUser.email,
        );
      }
    }
  } catch (err) {
    // Live read failed — try the webhook cache before giving up.
    let cached: TicketResult | null = null;
    try {
      const { data: { user: cardUser } } =
        await admin.auth.admin.getUserById(p.id);
      const email = cardUser?.email?.toLowerCase();
      const { data: claimRow } = await admin
        .from("ticket_claims")
        .select("shopify_order_id")
        .eq("profile_id", p.id)
        .eq("event", EVENT)
        .maybeSingle();
      let rows: Record<string, any>[] | null = null;
      if (claimRow) {
        const res = await admin.from("ticket_orders").select("*").eq(
          "shopify_order_id",
          (claimRow as { shopify_order_id: string }).shopify_order_id,
        );
        rows = res.data;
      } else if (email) {
        const res = await admin.from("ticket_orders").select("*")
          .eq("email", email);
        rows = res.data;
      }
      if (rows) {
        const row = rows.find((r: Record<string, any>) =>
          ["PAID", "PARTIALLY_PAID"].includes(r.status)
        );
        if (row) {
          cached = {
            has_ticket: true,
            ticket_type: "DAOS Party ticket",
            order_name: row.order_number ?? null,
            order_date: row.paid_at ?? null,
            cached: true,
          };
        }
      }
    } catch (_cacheErr) {
      cached = null;
    }
    if (cached) {
      ticket = cached;
    } else {
      const msg = err instanceof Error ? err.message : String(err);
      return json(
        { profile: publicProfile, error: `Ticket lookup failed: ${msg}` },
        502,
      );
    }
  }

  // Already checked in? (Read through the service role — check_ins has
  // no public policies at all.)
  const { data: existing } = await admin
    .from("check_ins")
    .select("checked_in_at")
    .eq("profile_id", p.id)
    .eq("event", EVENT)
    .maybeSingle();
  const alreadyCheckedIn = !!existing;
  const checkedInAt = existing
    ? (existing as { checked_in_at: string }).checked_in_at
    : null;

  if (action === "lookup") {
    return json({
      profile: publicProfile,
      ticket: { ...ticket, already_checked_in: alreadyCheckedIn, checked_in_at: checkedInAt },
    }, 200);
  }

  // Check-in action (staff only, enforced above).
  if (!ticket.has_ticket) {
    return json({
      profile: publicProfile,
      ticket: { ...ticket, already_checked_in: alreadyCheckedIn, checked_in_at: checkedInAt },
      error: "No ticket — sell at door",
    }, 200);
  }
  if (alreadyCheckedIn) {
    return json({
      profile: publicProfile,
      ticket: { ...ticket, already_checked_in: true, checked_in_at: checkedInAt },
      already_checked_in: true,
      checked_in_at: checkedInAt,
    }, 200);
  }
  const { data: inserted, error: insertError } = await admin
    .from("check_ins")
    .insert({
      profile_id: p.id,
      event: EVENT,
      checked_in_by: callerId,
    })
    .select("checked_in_at")
    .single();
  if (insertError) {
    // 23505 = unique (profile_id, event): another door phone checked
    // this person in a moment ago. Re-read and report that instead of
    // erroring — the person IS checked in.
    if ((insertError as { code?: string }).code === "23505") {
      const { data: raced } = await admin
        .from("check_ins")
        .select("checked_in_at")
        .eq("profile_id", p.id)
        .eq("event", EVENT)
        .maybeSingle();
      const at = raced
        ? (raced as { checked_in_at: string }).checked_in_at
        : checkedInAt;
      return json({
        profile: publicProfile,
        ticket: { ...ticket, already_checked_in: true, checked_in_at: at },
        already_checked_in: true,
        checked_in_at: at,
      }, 200);
    }
    return json(
      { error: `Could not record check-in: ${insertError.message}` },
      500,
    );
  }
  const at = (inserted as { checked_in_at: string }).checked_in_at;
  return json({
    profile: publicProfile,
    ticket: { ...ticket, already_checked_in: true, checked_in_at: at },
    checked_in: true,
    checked_in_at: at,
  }, 200);
});
