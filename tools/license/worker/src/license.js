// License keys in JavaScript, byte-compatible with tools/license/license_tool.py
// and LeonardCore/License/License.swift:
//   LEONARD-<base64url(payload JSON)>.<base64url(Ed25519 signature)>

export const PREFIX = "LEONARD-";

export function b64url(bytes) {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

export function unb64url(text) {
  const padded = text.replaceAll("-", "+").replaceAll("_", "/") + "=".repeat((4 - (text.length % 4)) % 4);
  const binary = atob(padded);
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

/** Imports the raw 32-byte Ed25519 seed (base64url, as written by
 *  `license_tool.py keygen`) together with its public key. */
export async function importSigningKey(seedB64, publicB64) {
  const jwk = { kty: "OKP", crv: "Ed25519", d: seedB64, x: publicB64, ext: false };
  return crypto.subtle.importKey("jwk", jwk, { name: "Ed25519" }, false, ["sign"]);
}

export function addYears(isoDate, years) {
  const [y, m, d] = isoDate.split("-").map(Number);
  const target = new Date(Date.UTC(y + years, m - 1, d));
  // 29 February in a non-leap year becomes 28 February, as in the Python tool.
  if (target.getUTCMonth() !== m - 1) target.setUTCDate(0);
  return target.toISOString().slice(0, 10);
}

export async function issue(key, { id, name, email, edition, seats, issued, updateYears = 1 }) {
  const payload = {
    v: 1,
    id,
    name,
    email,
    edition,
    seats,
    issued,
    updates_until: addYears(issued, updateYears),
  };
  const bytes = new TextEncoder().encode(JSON.stringify(payload));
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, key, bytes));
  return { key: PREFIX + b64url(bytes) + "." + b64url(signature), payload };
}
