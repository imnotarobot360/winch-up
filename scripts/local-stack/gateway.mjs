/**
 * A stand-in for Supabase's API gateway, for a machine that cannot run Docker.
 *
 * Supabase serves everything from one origin and routes by path prefix:
 *   /rest/v1/*     -> PostgREST        (the real binary, running here)
 *   /auth/v1/*     -> GoTrue           (a small shim, below)
 *   /storage/v1/*  -> storage-api      (not run; answers 501)
 *
 * PostgREST is the genuine article: same binary Supabase runs, same schema, real JWT role
 * switching, real RLS. The auth shim is NOT GoTrue — it implements just the four endpoints
 * supabase-js calls during a phone-OTP sign-in, against the real `auth.users` table, so that
 * /join, /me and /admin exercise their actual code paths. It accepts one fixed OTP and does no
 * rate limiting, so it belongs nowhere near production.
 *
 * Storage answers 501 rather than a fake success, so a test that needs it fails loudly.
 */
import crypto from "node:crypto";
import http from "node:http";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const PORT = 54321;
const POSTGREST = "http://127.0.0.1:54322";
const JWT_SECRET =
  process.env.LOCAL_JWT_SECRET ?? "txrecover-local-dev-jwt-secret-at-least-32-chars";
const TEST_OTP = process.env.LOCAL_TEST_OTP ?? "123456";
const PSQL = process.env.PSQL_BIN ?? "psql";
const PGURI =
  process.env.LOCAL_PG_URI ?? "postgres://postgres:postgres@127.0.0.1:55432/txrecover";

// ---------------------------------------------------------------------------
// JWT
// ---------------------------------------------------------------------------

const b64 = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");

function signJwt(claims, ttlSeconds = 60 * 60) {
  const now = Math.floor(Date.now() / 1000);
  const body = `${b64({ alg: "HS256", typ: "JWT" })}.${b64({
    iss: "supabase",
    iat: now,
    exp: now + ttlSeconds,
    ...claims,
  })}`;
  return `${body}.${crypto.createHmac("sha256", JWT_SECRET).update(body).digest("base64url")}`;
}

function verifyJwt(token) {
  if (!token) return null;
  const [header, payload, signature] = token.split(".");
  if (!header || !payload || !signature) return null;

  const expected = crypto
    .createHmac("sha256", JWT_SECRET)
    .update(`${header}.${payload}`)
    .digest("base64url");

  if (expected !== signature) return null;

  try {
    return JSON.parse(Buffer.from(payload, "base64url").toString());
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Postgres, via psql. The local stack already requires it, so this adds no dependency.
// ---------------------------------------------------------------------------

async function sql(statement) {
  const { stdout } = await execFileAsync(PSQL, [PGURI, "-t", "-A", "-F", "", "-c", statement]);
  return stdout
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => line.split(""));
}

const quote = (value) => `'${String(value).replace(/'/g, "''")}'`;

/** Find the auth user for a phone, creating one the way a first OTP sign-in would. */
async function findOrCreateUser(phone) {
  const existing = await sql(
    `select id::text, phone from auth.users where phone = ${quote(phone)} limit 1`,
  );
  if (existing.length) return { id: existing[0][0], phone: existing[0][1] };

  const created = await sql(
    `insert into auth.users (instance_id, id, aud, role, phone, phone_confirmed_at,
                             raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
     values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated',
             'authenticated', ${quote(phone)}, now(),
             '{"provider":"phone","providers":["phone"]}'::jsonb, '{}'::jsonb, now(), now())
     returning id::text, phone`,
  );
  return { id: created[0][0], phone: created[0][1] };
}

function sessionFor(user) {
  // Supabase puts the phone on the JWT; upsert_responder_profile reads it from there rather
  // than trusting the signup form, so it has to be present.
  const accessToken = signJwt({
    sub: user.id,
    role: "authenticated",
    aud: "authenticated",
    phone: user.phone.replace(/^\+/, ""),
  });

  return {
    access_token: accessToken,
    token_type: "bearer",
    expires_in: 3600,
    expires_at: Math.floor(Date.now() / 1000) + 3600,
    refresh_token: signJwt({ sub: user.id, typ: "refresh" }, 60 * 60 * 24 * 30),
    user: userObject(user),
  };
}

function userObject(user) {
  return {
    id: user.id,
    aud: "authenticated",
    role: "authenticated",
    phone: user.phone.replace(/^\+/, ""),
    app_metadata: { provider: "phone", providers: ["phone"] },
    user_metadata: {},
    identities: [],
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  };
}

// ---------------------------------------------------------------------------
// /auth/v1
// ---------------------------------------------------------------------------

async function handleAuth(req, res, url, body) {
  const json = (status, payload) => {
    res.writeHead(status, { "content-type": "application/json" });
    res.end(JSON.stringify(payload));
    console.log(`  ${status} ${req.method} ${url.pathname}`);
  };

  const parsed = body?.length ? JSON.parse(body.toString()) : {};
  const route = url.pathname.slice("/auth/v1".length);

  // Request a code. The shim does not send anything; the code is always TEST_OTP.
  if (route === "/otp" && req.method === "POST") {
    console.log(`  [auth shim] OTP for ${parsed.phone} is ${TEST_OTP}`);
    return json(200, { data: { user: null, session: null }, error: null });
  }

  if (route === "/verify" && req.method === "POST") {
    if (String(parsed.token) !== TEST_OTP) {
      return json(403, { error: "invalid_otp", error_description: "Token has expired or is invalid" });
    }
    const user = await findOrCreateUser(parsed.phone);
    return json(200, sessionFor(user));
  }

  if (route === "/user" && req.method === "GET") {
    const claims = verifyJwt((req.headers.authorization ?? "").replace(/^Bearer /, ""));
    if (!claims?.sub) return json(401, { message: "invalid claim: missing sub" });

    const rows = await sql(`select id::text, phone from auth.users where id = ${quote(claims.sub)}`);
    if (!rows.length) return json(404, { message: "User not found" });

    return json(200, userObject({ id: rows[0][0], phone: rows[0][1] ?? "" }));
  }

  if (route === "/token" && req.method === "POST") {
    const claims = verifyJwt(parsed.refresh_token);
    if (!claims?.sub) return json(401, { error: "invalid_grant" });

    const rows = await sql(`select id::text, phone from auth.users where id = ${quote(claims.sub)}`);
    if (!rows.length) return json(401, { error: "invalid_grant" });

    return json(200, sessionFor({ id: rows[0][0], phone: rows[0][1] ?? "" }));
  }

  if (route === "/logout") return json(204, {});

  return json(404, { message: `auth shim does not implement ${route}` });
}

// ---------------------------------------------------------------------------

/**
 * The browser talks to this origin directly for auth, so it needs CORS — real Supabase sends
 * these too. Without the OPTIONS handler the preflight 404s and the actual request never
 * happens, which surfaces in the UI as "we couldn't send the code".
 */
function applyCors(req, res) {
  res.setHeader("access-control-allow-origin", req.headers.origin ?? "*");
  res.setHeader("access-control-allow-credentials", "true");
  // Echo whatever the preflight asks for. supabase-js adds headers over time
  // (x-supabase-api-version was the one that caught this out), and a fixed list silently
  // blocks the request with a CORS error the app surfaces as "we couldn't send the code".
  res.setHeader(
    "access-control-allow-headers",
    req.headers["access-control-request-headers"] ??
      "authorization, apikey, content-type, x-client-info, x-supabase-api-version, accept, accept-profile, content-profile, prefer, range",
  );
  res.setHeader("access-control-allow-methods", "GET, POST, PATCH, PUT, DELETE, OPTIONS, HEAD");
  res.setHeader("access-control-expose-headers", "content-range, x-supabase-api-version");
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);

  applyCors(req, res);

  if (req.method === "OPTIONS") {
    res.writeHead(204);
    return res.end();
  }

  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const body = chunks.length ? Buffer.concat(chunks) : undefined;

  if (url.pathname.startsWith("/auth/v1")) {
    try {
      return await handleAuth(req, res, url, body);
    } catch (error) {
      console.error(`  500 ${req.method} ${url.pathname} - ${error.message}`);
      res.writeHead(500, { "content-type": "application/json" });
      return res.end(JSON.stringify({ message: error.message }));
    }
  }

  if (url.pathname.startsWith("/storage/v1")) {
    res.writeHead(501, { "content-type": "application/json" });
    console.log(`  501 ${req.method} ${url.pathname}  (storage-api not run locally)`);
    return res.end(
      JSON.stringify({
        error: "not_implemented_locally",
        message: "storage-api is not running locally - needs Docker or a cloud project.",
      }),
    );
  }

  if (!url.pathname.startsWith("/rest/v1")) {
    res.writeHead(404, { "content-type": "application/json" });
    return res.end(JSON.stringify({ error: "not_found" }));
  }

  const target = POSTGREST + url.pathname.slice("/rest/v1".length) + url.search;

  const headers = { ...req.headers };
  delete headers.host;
  delete headers.connection;
  delete headers["content-length"];

  try {
    const upstream = await fetch(target, { method: req.method, headers, body });
    const text = await upstream.text();

    console.log(`  ${upstream.status} ${req.method} ${url.pathname}${url.search.slice(0, 60)}`);

    res.writeHead(upstream.status, {
      "content-type": upstream.headers.get("content-type") ?? "application/json",
    });
    res.end(text);
  } catch (error) {
    console.error(`  502 ${req.method} ${url.pathname} - ${error.message}`);
    res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "bad_gateway", message: error.message }));
  }
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`gateway  http://127.0.0.1:${PORT}`);
  console.log(`  /rest/v1    -> PostgREST ${POSTGREST}`);
  console.log(`  /auth/v1    -> shim (OTP is always ${TEST_OTP})`);
  console.log(`  /storage/v1 -> 501`);
});
