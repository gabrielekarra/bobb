// The only place business URLs live. Fill these in before deploying the site;
// see docs/LAUNCH.md. Anything left empty falls back to email.
window.LEONARD = {
  version: "1.0.0",
  minimumMacOS: "14.0",
  // The notarized DMG, e.g. a public Cloudflare R2 bucket or a GitHub
  // release asset. Its SHA-256 is printed by scripts/package.sh.
  downloadURL: "",
  downloadSHA256: "",
  // Lemon Squeezy (or Paddle) checkout links per plan. The store's webhook
  // points at tools/license/worker, which emails the license key.
  checkout: {
    personal: "",
    pro: "",
  },
  supportEmail: "support@leonard.app",
  salesEmail: "sales@leonard.app",
};
