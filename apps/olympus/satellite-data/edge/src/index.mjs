/** @param {number} status @param {string} message @param {boolean} head */
function problem(status, message, head) {
  return new Response(head ? null : JSON.stringify({error: message}), {
    status,
    headers: {'Content-Type': 'application/json', 'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff', ...(status === 405 ? {Allow: 'GET, HEAD'} : {})},
  });
}

/** @satisfies {ExportedHandler<Env>} */
export default {
  async fetch(request, env) {
    const head = request.method === 'HEAD';
    if (request.method !== 'GET' && !head) return problem(405, 'Method not allowed', false);
    const url = new URL(request.url);
    if (url.protocol !== 'https:' || url.hostname !== 'data.cosmotrak.com' || url.search) {
      return problem(404, 'Not found', head);
    }
    const manifest = url.pathname === '/v1/manifest.json';
    if (!manifest && !/^\/v1\/databases\/[a-f0-9]{64}\.db$/.test(url.pathname)) {
      return problem(404, 'Not found', head);
    }
    try {
      const key = url.pathname.slice(1);
      const fetched = head ? null : await env.DATABASES.get(key);
      const object = head ? await env.DATABASES.head(key) : fetched;
      if (!object) return problem(404, 'Not found', head);
      const headers = new Headers({
        'Content-Type': manifest ? 'application/json' : 'application/vnd.sqlite3',
        'Content-Length': String(object.size),
        'Content-Encoding': 'identity',
        'Cache-Control': manifest ? 'no-cache, max-age=0, must-revalidate, no-transform'
          : 'public, max-age=31536000, immutable, no-transform',
        ETag: object.httpEtag,
        'X-Content-Type-Options': 'nosniff',
      });
      if (request.headers.get('If-None-Match') === object.httpEtag) {
        if (fetched) await fetched.body.cancel();
        headers.delete('Content-Length');
        return new Response(null, {status: 304, headers});
      }
      return new Response(fetched?.body ?? null, {headers, encodeBody: 'manual'});
    } catch {
      console.error(JSON.stringify({event: 'r2_read_failed', resource: manifest ? 'manifest' : 'database'}));
      return problem(503, 'Delivery temporarily unavailable', head);
    }
  },
};
