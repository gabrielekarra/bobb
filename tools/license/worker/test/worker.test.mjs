import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import worker, { emailFor, orderFromWebhook, verifySignature } from "../src/index.js";
import { PREFIX, addYears, importSigningKey, issue, unb64url } from "../src/license.js";

const here = dirname(fileURLToPath(import.meta.url));
const toolDir = join(here, "..", "..");
const DEV_SEED = readFileSync(join(toolDir, "dev-signing.key"), "utf8").trim();
const DEV_PUBLIC = "pKVQLNy-XRirFvGnkNLtDBOHwpeMoz81bSN3RwGKy08";

const env = {
  WEBHOOK_SECRET: "whsec_test",
  SIGNING_KEY: DEV_SEED,
  PUBLIC_KEY: DEV_PUBLIC,
  VARIANT_PERSONAL: "111",
  VARIANT_PRO: "222",
  FROM_EMAIL: "Bobb <licenses@bobb.app>",
  SUPPORT_EMAIL: "support@bobb.app",
  RESEND_API_KEY: "re_test",
};

function orderEvent({ variant = "222", status = "paid", quantity = 1, lang = "it" } = {}) {
  return {
    meta: { event_name: "order_created", custom_data: { lang } },
    data: {
      id: "98765",
      attributes: {
        status,
        user_name: "Studio Rossi",
        user_email: "marco@studiorossi.it",
        created_at: "2026-09-28T10:00:00.000000Z",
        first_order_item: { variant_id: Number(variant), quantity },
      },
    },
  };
}

async function hmac(secret, body) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body)));
  return [...mac].map((b) => b.toString(16).padStart(2, "0")).join("");
}

test("keys issued in JavaScript verify with the Python tool", async () => {
  const key = await importSigningKey(DEV_SEED, DEV_PUBLIC);
  const { key: license } = await issue(key, { id: "lic_js", name: "Studio Rossi", email: "m@x.it", edition: "pro", seats: 3, issued: "2026-09-28" });
  const out = execFileSync(join(toolDir, ".venv", "bin", "python"), [join(toolDir, "license_tool.py"), "verify", "--public", DEV_PUBLIC, license], { encoding: "utf8" });
  const payload = JSON.parse(out);
  assert.equal(payload.updates_until, "2027-09-28");
  assert.equal(payload.edition, "pro");
});

test("the Python tool re-issues the worker's exact key from the order", async () => {
  const key = await importSigningKey(DEV_SEED, DEV_PUBLIC);
  const order = { id: "lic_ls_98765", name: "Studio Rossi è", email: "m@x.it", edition: "pro", seats: 3, issued: "2026-09-28" };
  const { key: fromWorker } = await issue(key, order);
  const fromTool = execFileSync(join(toolDir, ".venv", "bin", "python"), [
    join(toolDir, "license_tool.py"), "issue", "--key", join(toolDir, "dev-signing.key"),
    "--name", order.name, "--email", order.email, "--edition", "pro", "--seats", "3",
    "--id", order.id, "--issued", order.issued,
  ], { encoding: "utf8" }).trim();
  assert.equal(fromTool, fromWorker);
});

test("signatures are deterministic, so a retried webhook re-sends the same key", async () => {
  const key = await importSigningKey(DEV_SEED, DEV_PUBLIC);
  const order = { id: "lic_ls_1", name: "A", email: "a@b.c", edition: "personal", seats: 2, issued: "2026-09-28" };
  assert.equal((await issue(key, order)).key, (await issue(key, order)).key);
});

test("leap days end on 28 February", () => {
  assert.equal(addYears("2028-02-29", 1), "2029-02-28");
  assert.equal(addYears("2026-09-28", 1), "2027-09-28");
});

test("webhook signatures are checked", async () => {
  assert.equal(await verifySignature("s", "body", await hmac("s", "body")), true);
  assert.equal(await verifySignature("s", "body", await hmac("other", "body")), false);
  assert.equal(await verifySignature("s", "body", null), false);
});

test("orders map to editions and seats; unpaid and unknown are refused", () => {
  assert.equal(orderFromWebhook(orderEvent({ variant: "111" }), env).order.edition, "personal");
  assert.equal(orderFromWebhook(orderEvent({ variant: "222", quantity: 2 }), env).order.seats, 6);
  assert.match(orderFromWebhook(orderEvent({ status: "pending" }), env).skip, /pending/);
  assert.match(orderFromWebhook(orderEvent({ variant: "999" }), env).error, /unknown variant/);
  assert.match(orderFromWebhook({ meta: { event_name: "subscription_created" } }, env).skip, /not an order/);
});

test("the email is in the buyer's language and carries the key", () => {
  const { order } = orderFromWebhook(orderEvent({ lang: "it" }), env);
  const email = emailFor(order, "BOBB-abc.def", env);
  assert.equal(email.subject, "La tua licenza di Bobb");
  assert.match(email.text, /BOBB-abc\.def/);
  assert.match(email.text, /Impostazioni › Licenza/);
});

test("end to end: a signed webhook produces an email with a valid key", async () => {
  const body = JSON.stringify(orderEvent());
  let sentEmail;
  globalThis.fetch = async (url, init) => {
    assert.equal(url, "https://api.resend.com/emails");
    sentEmail = JSON.parse(init.body);
    return new Response("{}", { status: 200 });
  };
  const request = new Request("https://licenses.bobb.app/webhook", {
    method: "POST", body, headers: { "X-Signature": await hmac(env.WEBHOOK_SECRET, body) },
  });
  const response = await worker.fetch(request, env);
  assert.equal(response.status, 200);
  const license = sentEmail.text.match(/BOBB-[A-Za-z0-9_.-]+/)[0];
  const payload = JSON.parse(new TextDecoder().decode(unb64url(license.slice(PREFIX.length).split(".")[0])));
  assert.equal(payload.id, "lic_ls_98765");
  assert.equal(payload.seats, 3);

  const forged = new Request("https://licenses.bobb.app/webhook", { method: "POST", body, headers: { "X-Signature": "00" } });
  assert.equal((await worker.fetch(forged, env)).status, 401);
});
