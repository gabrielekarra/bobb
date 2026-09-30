// Bobb license fulfillment: a Cloudflare Worker.
//
// Lemon Squeezy calls POST /webhook when an order is paid. The worker checks
// the webhook's HMAC signature, maps the purchased variant to an edition,
// signs a license key with the Ed25519 signing key, and emails it to the
// buyer. The key is derived only from the order, and Ed25519 signatures are
// deterministic, so a retried webhook re-sends the same key rather than
// minting a second one. The worker stores nothing.
//
// Secrets (wrangler secret put): WEBHOOK_SECRET, SIGNING_KEY (base64url seed),
// RESEND_API_KEY. Vars (wrangler.toml): PUBLIC_KEY, VARIANT_PERSONAL,
// VARIANT_PRO, FROM_EMAIL, SUPPORT_EMAIL.

import { importSigningKey, issue } from "./license.js";

const EDITIONS = {
  personal: { seats: 2 },
  pro: { seats: 3 },
};

export async function verifySignature(secret, body, signatureHex) {
  if (!signatureHex) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body)));
  const expected = [...mac].map((b) => b.toString(16).padStart(2, "0")).join("");
  if (expected.length !== signatureHex.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ signatureHex.charCodeAt(i);
  return diff === 0;
}

export function orderFromWebhook(event, env) {
  if (event?.meta?.event_name !== "order_created") return { skip: "not an order" };
  const attributes = event.data?.attributes ?? {};
  if (attributes.status !== "paid") return { skip: `order status ${attributes.status}` };
  const variant = String(attributes.first_order_item?.variant_id ?? "");
  const edition = variant === String(env.VARIANT_PRO) ? "pro" : variant === String(env.VARIANT_PERSONAL) ? "personal" : null;
  if (!edition) return { error: `unknown variant ${variant}` };
  const quantity = Math.max(1, Number(attributes.first_order_item?.quantity ?? 1));
  return {
    order: {
      id: `lic_ls_${event.data.id}`,
      name: attributes.user_name || attributes.user_email,
      email: attributes.user_email,
      edition,
      seats: EDITIONS[edition].seats * quantity,
      issued: (attributes.created_at || new Date().toISOString()).slice(0, 10),
      locale: String(event.meta?.custom_data?.lang || "").startsWith("it") ? "it" : "en",
    },
  };
}

export function emailFor(order, licenseKey, env) {
  const it = order.locale === "it";
  const subject = it ? "La tua licenza di Bobb" : "Your Bobb license";
  const text = it
    ? `Ciao ${order.name},\n\ngrazie per aver scelto Bobb ${order.edition === "pro" ? "Pro" : "Personal"}.\n\nLa tua chiave di licenza:\n\n${licenseKey}\n\nPer attivarla: apri Bobb dalla barra dei menu, Impostazioni › Licenza, incolla la chiave e premi Attiva. La chiave viene verificata sul tuo Mac: niente viene inviato a noi.\n\nLa licenza vale per ${order.seats} Mac e include un anno di aggiornamenti. Conserva questa email.\n\nPer qualsiasi cosa: ${env.SUPPORT_EMAIL}\n\n— Bobb`
    : `Hi ${order.name},\n\nthank you for choosing Bobb ${order.edition === "pro" ? "Pro" : "Personal"}.\n\nYour license key:\n\n${licenseKey}\n\nTo activate it: open Bobb from the menu bar, go to Settings › License, paste the key and press Activate. The key is checked on your Mac; nothing is sent to us.\n\nYour license covers ${order.seats} Macs and includes a year of updates. Keep this email.\n\nAnything at all: ${env.SUPPORT_EMAIL}\n\n— Bobb`;
  return { from: env.FROM_EMAIL, to: [order.email], reply_to: env.SUPPORT_EMAIL, subject, text };
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") {
      return Response.json({ ok: true, public_key: env.PUBLIC_KEY });
    }
    if (request.method !== "POST" || url.pathname !== "/webhook") {
      return new Response("not found", { status: 404 });
    }
    const body = await request.text();
    if (!(await verifySignature(env.WEBHOOK_SECRET, body, request.headers.get("X-Signature")))) {
      return new Response("bad signature", { status: 401 });
    }
    const parsed = orderFromWebhook(JSON.parse(body), env);
    if (parsed.skip) return Response.json({ ok: true, skipped: parsed.skip });
    if (parsed.error) return Response.json({ ok: false, error: parsed.error }, { status: 422 });

    const signingKey = await importSigningKey(env.SIGNING_KEY, env.PUBLIC_KEY);
    const { key } = await issue(signingKey, parsed.order);
    const sent = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify(emailFor(parsed.order, key, env)),
    });
    if (!sent.ok) {
      // A 5xx makes Lemon Squeezy retry; the same order yields the same key.
      return Response.json({ ok: false, error: `email ${sent.status}` }, { status: 502 });
    }
    return Response.json({ ok: true, license_id: parsed.order.id });
  },
};
