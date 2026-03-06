/**
 * Exchange a base64-encoded Google service account JSON for a short-lived OAuth2 Bearer token.
 * Uses only Deno built-ins (crypto.subtle) — no external dependencies.
 */
export async function getGoogleAccessToken(
  credentialsBase64: string,
  scopes: string[],
): Promise<string> {
  const credentials = JSON.parse(atob(credentialsBase64));
  const { client_email, private_key } = credentials as {
    client_email: string;
    private_key: string;
  };

  // --- Build JWT ---
  const now = Math.floor(Date.now() / 1000);

  const base64url = (obj: unknown): string =>
    btoa(JSON.stringify(obj))
      .replace(/=/g, "")
      .replace(/\+/g, "-")
      .replace(/\//g, "_");

  const header = base64url({ alg: "RS256", typ: "JWT" });
  const payload = base64url({
    iss: client_email,
    scope: scopes.join(" "),
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  });

  const signingInput = `${header}.${payload}`;

  // --- Import RSA private key from PEM ---
  const pemBody = private_key
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s/g, "");

  const keyDer = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));

  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    keyDer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );

  // --- Sign ---
  const signatureBuffer = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    new TextEncoder().encode(signingInput),
  );

  const signature = btoa(
    String.fromCharCode(...new Uint8Array(signatureBuffer)),
  ).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");

  const jwt = `${signingInput}.${signature}`;

  // --- Exchange JWT for access token ---
  const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });

  if (!tokenRes.ok) {
    const errText = await tokenRes.text();
    throw new Error(
      `Failed to obtain Google access token: ${tokenRes.status} ${errText}`,
    );
  }

  const tokenData = await tokenRes.json();
  return tokenData.access_token as string;
}
