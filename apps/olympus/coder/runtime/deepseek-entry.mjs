// Coder authenticates the owner before forwarding to this loopback-only adapter.
// Exchange DSH's per-boot token for its normal HttpOnly cookie; never expose or
// patch the vendor token/auth implementation. All API/WebSocket checks remain.
import http from 'node:http';
import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';

const port = Number(process.env.OLYMPUS_DSH_PORT || 13340);
const upstreamPort = Number(process.env.OLYMPUS_DSH_BACKEND_PORT || 13346);
const e = process.env;
const publicHost = e.OLYMPUS_CODER_WORKSPACE &&
  `deepseek--${e.OLYMPUS_CODER_AGENT}--${e.OLYMPUS_CODER_WORKSPACE}--${e.OLYMPUS_CODER_OWNER}.${e.OLYMPUS_CODER_WILDCARD_DOMAIN}`;
const hosts = new Set([`127.0.0.1:${port}`, `localhost:${port}`, ...(publicHost ? [publicHost] : [])]);
let token;
const child = spawn('/opt/olympus/bin/dsh', ['web', '--no-open', '--host', '127.0.0.1',
  '--port', String(upstreamPort), ...(publicHost ? ['--trusted-host', publicHost] : [])],
  {stdio: ['ignore', 'pipe', 'pipe']});
for (const stream of [child.stdout, child.stderr]) {
  createInterface({input: stream}).on('line', line => {
    const match = line.match(/dsh web: http:\/\/127\.0\.0\.1:\d+\/\?token=([A-Za-z0-9_-]+)/);
    if (match) token = match[1];
    console.log(line.replace(/([?&]token=)[^\s&]+/g, '$1[redacted]'));
  });
}
child.on('error', () => process.exit(1));
child.on('exit', () => process.exit(1));
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => {
  child.kill(signal);
  server.close();
});

function allowed(req) {
  if (!hosts.has(req.headers.host)) return false;
  if (req.headers['sec-fetch-site'] === 'cross-site') return false;
  if (req.headers.origin) {
    try { if (new URL(req.headers.origin).host !== req.headers.host) return false; }
    catch { return false; }
  }
  return true;
}
function options(req, path = req.url) {
  return {hostname: '127.0.0.1', port: upstreamPort, method: req.method,
    path, headers: {...req.headers}, timeout: 30000};
}
const server = http.createServer((req, res) => {
  if (!allowed(req)) { res.writeHead(403).end('Invalid application origin'); return; }
  const health = req.method === 'GET' && req.url === '/__olympus_health';
  const forward = (path, retry = false) => {
    const proxy = http.request(options(req, path), upstream => {
      if (health) {
        upstream.resume();
        res.writeHead(token && [200, 401].includes(upstream.statusCode) ? 200 : 503,
          {'content-type': 'text/plain', 'cache-control': 'no-store'}).end('DeepSeek runtime');
      } else if (!retry && req.method === 'GET' && req.url === '/' && upstream.statusCode === 401 && token) {
        upstream.resume();
        forward('/?token=' + encodeURIComponent(token), true);
      } else {
        res.writeHead(upstream.statusCode, upstream.headers);
        upstream.pipe(res);
      }
    });
    proxy.on('error', () => { if (!res.headersSent) res.writeHead(503); res.end('DeepSeek is starting'); });
    proxy.on('timeout', () => proxy.destroy());
    if (retry || health) proxy.end(); else req.pipe(proxy);
  };
  forward(health ? '/' : req.url);
});
server.on('upgrade', (req, socket, head) => {
  if (!allowed(req)) { socket.destroy(); return; }
  const proxy = http.request(options(req));
  proxy.on('upgrade', (res, upstream, upstreamHead) => {
    socket.write(`HTTP/1.1 ${res.statusCode} ${res.statusMessage}\r\n`);
    for (let i = 0; i < res.rawHeaders.length; i += 2)
      socket.write(`${res.rawHeaders[i]}: ${res.rawHeaders[i + 1]}\r\n`);
    socket.write('\r\n');
    if (upstreamHead.length) socket.write(upstreamHead);
    if (head.length) upstream.write(head);
    upstream.on('error', () => socket.destroy());
    socket.on('error', () => upstream.destroy());
    upstream.pipe(socket).pipe(upstream);
  });
  proxy.on('response', res => { res.resume(); socket.destroy(); });
  proxy.on('error', () => socket.destroy());
  proxy.end();
});
server.listen(port, '127.0.0.1');
