"""Run from a tailnet client: python verify.py [--write]. Python 3.11+, stdlib only.

Uses PARTDB_TOKEN or the local Codex partdb configuration. --write creates,
updates, reads and removes only one uniquely named temporary category.
"""
import json
import os
from pathlib import Path
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request
import uuid

PUBLIC = 'https://partdb.jacob-neel.dev'
PRIVATE = 'http://olympus-partdb.taild90e78.ts.net'

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None

http = urllib.request.build_opener(NoRedirect)

def request(url, data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers={
        'User-Agent': 'curl/8.14.1', **(headers or {})})
    try:
        response = http.open(req, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    return response.status, response.headers, response.read()

def main():
    token = os.environ.get('PARTDB_TOKEN')
    if not token:
        config = tomllib.loads((Path.home()/'.codex/config.toml').read_text(encoding='utf-8'))
        token = config['mcp_servers']['partdb']['http_headers']['Authorization'].removeprefix('Bearer ')
    headers = {'Authorization': 'Bearer '+token,
               'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream'}
    assert request(PUBLIC+'/en/login')[0] == 200
    status, fields, _ = request(PUBLIC.replace('https:', 'http:')+'/en/login')
    assert status == 308 and fields['Location'] == PUBLIC+'/en/login'
    assert request(PUBLIC+'/mcp')[0] == 404
    # Check the origin's independent host restriction, even with a valid token.
    assert request(PRIVATE+'/mcp', headers={**headers, 'Host': 'partdb.jacob-neel.dev',
                                          'X-Forwarded-Proto': 'https'})[0] == 403
    assert request(PRIVATE+'/mcp')[0] in (302, 401, 403)
    assert request(PRIVATE+'/api/parts', headers={'Accept': 'application/json'})[0] in (401, 403)
    assert request(PRIVATE+'/en/parts')[0] == 302
    assert request(PRIVATE+'/en/login', headers={'Host':'invalid.example'})[0] == 400
    status, fields, _ = request(PUBLIC+'/saml/login')
    assert status == 302
    redirect = urllib.parse.urlsplit(fields['Location'])
    assert redirect.hostname == 'auth.jacob-neel.dev'
    assert urllib.parse.parse_qs(redirect.query)['RelayState'][0].startswith(PUBLIC+'/')

    counter = 0
    def rpc(method, params, notification=False):
        nonlocal counter
        counter += 1
        payload = {'jsonrpc':'2.0', 'method':method, 'params':params}
        if not notification:
            payload['id'] = counter
        status, fields, body = request(PRIVATE+'/mcp', json.dumps(payload).encode(), headers)
        assert status in (200, 202), (method, status, body[:300])
        if fields.get('Mcp-Session-Id'):
            headers['Mcp-Session-Id'] = fields['Mcp-Session-Id']
        if notification:
            return None
        if fields.get_content_type() == 'text/event-stream':
            body = next(line[5:] for line in body.splitlines() if line.startswith(b'data:'))
        result = json.loads(body)
        assert 'error' not in result, result
        result = result['result']
        assert not result.get('isError'), result
        return result

    rpc('initialize', {'protocolVersion':'2025-03-26', 'capabilities':{},
                      'clientInfo':{'name':'olympus-partdb-verification', 'version':'1'}})
    rpc('notifications/initialized', {}, notification=True)
    tools = rpc('tools/list', {})['tools']
    names = {t['name'] for t in tools}
    assert {'search_parts','create_part','update_part','add_part_stock','delete_category'} <= names
    def call(name, arguments):
        result = rpc('tools/call', {'name':name, 'arguments':arguments})
        if 'structuredContent' in result:
            return result['structuredContent']
        text = next((x['text'] for x in result.get('content',[]) if x['type']=='text'), '{}')
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return text
    call('list_categories', {})
    if '--write' in sys.argv:
        name = 'MCP verification '+uuid.uuid4().hex
        category = call('create_category', {'name':name, 'logComment':'Temporary deployment verification'})
        category_id = category['id']
        try:
            assert call('get_category_details', {'id':category_id})['name'] == name
            updated = call('update_category', {'id':category_id, 'comment':'Edit permission verified'})
            assert updated['comment'] == 'Edit permission verified'
        finally:
            assert call('get_category_details', {'id':category_id})['name'] == name
            call('delete_category', {'id':category_id, 'logComment':'Remove temporary deployment verification'})
        assert name not in json.dumps(call('list_categories', {'keyword':name}))
    print(f'PASS: HTTPS, SAML redirect, access restrictions, {len(tools)} MCP tools, reads'
          + (', and create/read/update/delete with cleanup' if '--write' in sys.argv else ''))

if __name__ == '__main__':
    main()
