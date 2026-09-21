/**
 * A stand-in for Supabase's API gateway, for a machine that cannot run Docker.
 *
 * Supabase serves everything from one origin and routes by path prefix:
 *   /rest/v1/*     -> PostgREST        (this is what supabase-js .from() and .rpc() call)
 *   /auth/v1/*     -> GoTrue           (not run here)
 *   /storage/v1/*  -> storage-api      (not run here)
 *
 * PostgREST alone is the real thing: the same binary Supabase runs, against the real schema,
 * with real JWT role switching and real RLS. The two it cannot cover are stubbed with an honest
 * 501 rather than a fake success, so a test that needs them fails loudly instead of passing for
 * the wrong reason.
 */
import http from "node:http";

const PORT = 54321;
const POSTGREST = "http://127.0.0.1:54322";

const NOT_RUN = {
  "/auth/v1": "GoTrue (phone OTP) is not running locally - needs Docker or a cloud project.",
  "/storage/v1": "storage-api is not running locally - needs Docker or a cloud project.",
};

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);

  for (const [prefix, why] of Object.entries(NOT_RUN)) {
    if (url.pathname.startsWith(prefix)) {
      res.writeHead(501, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "not_implemented_locally", message: why }));
      console.log(`  501 ${req.method} ${url.pathname}  (${prefix} not run locally)`);
      return;
    }
  }

  if (!url.pathname.startsWith("/rest/v1")) {
    res.writeHead(404, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "not_found" }));
    return;
  }

  const target = POSTGREST + url.pathname.slice("/rest/v1".length) + url.search;

  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const body = chunks.length ? Buffer.concat(chunks) : undefined;

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
  console.log(`supabase-ish gateway on http://127.0.0.1:${PORT}  ->  PostgREST ${POSTGREST}`);
});
