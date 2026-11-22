const target = (process.env.API_TARGET ?? "http://127.0.0.1:8787").replace(/\/+$/, "");
const port = Number(process.env.PORT ?? 4173);

const root = new URL("./dist/", import.meta.url);
const index = new URL("./index.html", root);
const hasBuild = await Bun.file(index).exists();

const server = Bun.serve({
  port,
  hostname: "0.0.0.0",
  async fetch(request) {
    const url = new URL(request.url);

    if (url.pathname.startsWith("/api/")) {
      const upstream = new URL(url.pathname + url.search, target);
      const headers = new Headers(request.headers);
      headers.delete("host");

      try {
        return await fetch(upstream, {
          method: request.method,
          headers,
          body:
            request.method === "GET" || request.method === "HEAD"
              ? undefined
              : request.body,
        });
      } catch {
        return new Response(
          JSON.stringify({ error: `API unreachable at ${target}` }),
          {
            status: 502,
            headers: { "Content-Type": "application/json; charset=utf-8" },
          },
        );
      }
    }

    if (!hasBuild) {
      return new Response("Run `bun run build` first.", {
        status: 503,
        headers: { "Content-Type": "text/plain; charset=utf-8" },
      });
    }

    let relative = decodeURIComponent(url.pathname).replace(/^\/+/, "");
    if (relative === "") {
      relative = "index.html";
    }
    if (relative.includes("..")) {
      return new Response("Not found", { status: 404 });
    }

    let file = Bun.file(new URL(relative, root));
    if (!(await file.exists())) {
      file = Bun.file(index);
    }
    return new Response(file);
  },
});

console.log(`NixOS Control web: http://localhost:${server.port} (API ${target})`);