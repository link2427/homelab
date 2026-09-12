import assert from 'node:assert/strict';
import {after, before, test} from 'node:test';
import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {Miniflare, convertV4MiniflareOptions} from 'miniflare';
import handler from '../src/index.mjs';

let runtime;
let bucket;
const data = Uint8Array.from({length: 131072}, (_, i) => i % 256);
const sha = createHash('sha256').update(data).digest('hex');
const path = `/v1/databases/${sha}.db`;
const manifest = JSON.stringify({format: 'test-manifest', database: {sha256: sha}});

before(async () => {
  runtime = new Miniflare(convertV4MiniflareOptions({name: 'delivery', modules: true, script: await readFile(new URL('../src/index.mjs', import.meta.url), 'utf8'),
    compatibilityDate: '2026-09-12', compatibilityFlags: ['nodejs_compat'], r2Buckets: ['DATABASES']}));
  bucket = await runtime.getR2Bucket('DATABASES');
  await bucket.put(path.slice(1), data);
  await bucket.put('v1/manifest.json', manifest);
  await bucket.put('status.json', 'private');
  await bucket.put('Satellite_Database/logs/private.json', 'private');
});
after(async () => {await runtime?.dispose();});

test('full binary GET preserves bytes, length, type and immutable caching', async () => {
  const response = await runtime.dispatchFetch('https://data.cosmotrak.com' + path, {headers: {'Accept-Encoding': 'gzip, br'}});
  const bytes = Buffer.from(await response.arrayBuffer());
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Content-Type'), 'application/vnd.sqlite3');
  assert.equal(response.headers.get('Content-Length'), String(data.length));
  assert.ok([null, 'identity'].includes(response.headers.get('Content-Encoding')));
  assert.match(response.headers.get('Cache-Control'), /max-age=31536000, immutable, no-transform/);
  assert.equal(createHash('sha256').update(bytes).digest('hex'), sha);
});

test('HEAD returns exact metadata with no body', async () => {
  const response = await runtime.dispatchFetch('https://data.cosmotrak.com' + path, {method:'HEAD'});
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Content-Length'), String(data.length));
  assert.equal((await response.arrayBuffer()).byteLength, 0);
});

test('manifest requires revalidation and conditional request returns 304', async () => {
  const response = await runtime.dispatchFetch('https://data.cosmotrak.com/v1/manifest.json');
  assert.equal(await response.text(), manifest);
  assert.match(response.headers.get('Cache-Control'), /no-cache, max-age=0, must-revalidate/);
  const conditional = await runtime.dispatchFetch('https://data.cosmotrak.com/v1/manifest.json', {headers: {'If-None-Match': response.headers.get('ETag')}});
  assert.equal(conditional.status, 304);
  assert.equal(await conditional.text(), '');
});

test('listings, private keys, queries, other hosts and non-HTTPS are rejected', async () => {
  for (const url of ['https://data.cosmotrak.com/', 'https://data.cosmotrak.com/status.json',
    'https://data.cosmotrak.com/Satellite_Database/logs/private.json', 'https://data.cosmotrak.com/v1/databases/',
    'https://data.cosmotrak.com/v1/databases/' + sha.toUpperCase() + '.db',
    'https://data.cosmotrak.com/v1/manifest.json?list-type=2', 'https://other.example/v1/manifest.json',
    'http://data.cosmotrak.com/v1/manifest.json']) {
    const response = await runtime.dispatchFetch(url);
    assert.equal(response.status, 404, url);
    assert.equal(response.headers.get('Cache-Control'), 'no-store');
    await response.text();
  }
});

test('write methods cannot change the object', async () => {
  for (const method of ['PUT','POST','DELETE','PATCH','OPTIONS']) {
    const response = await runtime.dispatchFetch('https://data.cosmotrak.com/v1/manifest.json', {method});
    assert.equal(response.status, 405);
    assert.equal(response.headers.get('Allow'), 'GET, HEAD');
    await response.text();
  }
  assert.equal(await (await bucket.get('v1/manifest.json')).text(), manifest);
});

test('missing objects are 404 and storage failures are sanitized 503', async () => {
  const missing = await runtime.dispatchFetch('https://data.cosmotrak.com/v1/databases/' + '0'.repeat(64) + '.db');
  assert.equal(missing.status, 404);
  await missing.text();
  const failed = await handler.fetch(new Request('https://data.cosmotrak.com/v1/manifest.json'), {
    DATABASES: {get: async () => {throw new Error('private storage detail');}},
  });
  assert.equal(failed.status, 503);
  assert.equal(await failed.text(), JSON.stringify({error: 'Delivery temporarily unavailable'}));
});
