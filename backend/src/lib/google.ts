import { ApiError } from './errors';

const JWKS_URL = 'https://www.googleapis.com/oauth2/v3/certs';
const VALID_ISSUERS = new Set(['accounts.google.com', 'https://accounts.google.com']);

interface Jwk { kid: string; n: string; e: string; alg: string; kty: string }

export interface GoogleIdTokenClaims {
  sub: string;
  email: string;
  email_verified?: boolean;
  name?: string;
  picture?: string;
  aud: string;
  iss: string;
  exp: number;
}

let jwksCache: { keys: Jwk[]; fetchedAt: number } | null = null;
const JWKS_TTL_MS = 60 * 60 * 1000;

async function getJwks(): Promise<Jwk[]> {
  if (jwksCache && Date.now() - jwksCache.fetchedAt < JWKS_TTL_MS) return jwksCache.keys;
  const res = await fetch(JWKS_URL);
  if (!res.ok) throw new ApiError('INTERNAL', 'Cannot fetch Google JWKS');
  const body = (await res.json()) as { keys: Jwk[] };
  jwksCache = { keys: body.keys, fetchedAt: Date.now() };
  return body.keys;
}

function b64urlToBytes(s: string): Uint8Array {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(s.length / 4) * 4, '=');
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/**
 * Verifies a Google id_token: RS256 signature against the published JWKS, then
 * issuer, audience and expiry. Throws ApiError('UNAUTHENTICATED') on any failure.
 */
export async function verifyGoogleIdToken(
  idToken: string, allowedAudiences: string[],
): Promise<GoogleIdTokenClaims> {
  const parts = idToken.split('.');
  if (parts.length !== 3) throw new ApiError('UNAUTHENTICATED', 'Malformed id_token');
  const [headerB64, payloadB64, signatureB64] = parts as [string, string, string];

  const header = JSON.parse(new TextDecoder().decode(b64urlToBytes(headerB64))) as
    { kid?: string; alg?: string };
  if (header.alg !== 'RS256') throw new ApiError('UNAUTHENTICATED', 'Unexpected id_token alg');

  const jwk = (await getJwks()).find((k) => k.kid === header.kid);
  if (!jwk) throw new ApiError('UNAUTHENTICATED', 'Unknown id_token key id');

  const key = await crypto.subtle.importKey(
    'jwk',
    { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: 'RS256', ext: true },
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['verify'],
  );
  const ok = await crypto.subtle.verify(
    'RSASSA-PKCS1-v1_5',
    key,
    b64urlToBytes(signatureB64),
    new TextEncoder().encode(`${headerB64}.${payloadB64}`),
  );
  if (!ok) throw new ApiError('UNAUTHENTICATED', 'Invalid id_token signature');

  const claims = JSON.parse(
    new TextDecoder().decode(b64urlToBytes(payloadB64)),
  ) as GoogleIdTokenClaims;

  if (!VALID_ISSUERS.has(claims.iss)) {
    throw new ApiError('UNAUTHENTICATED', 'Invalid id_token issuer');
  }
  if (!allowedAudiences.includes(claims.aud)) {
    throw new ApiError('UNAUTHENTICATED', 'id_token audience not allowed');
  }
  if (claims.exp * 1000 <= Date.now()) {
    throw new ApiError('UNAUTHENTICATED', 'id_token expired');
  }
  return claims;
}
