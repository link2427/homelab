"""Outside-cluster satellite monitor. Never contacts CelesTrak.

Prints a transition event, then saves state atomically. No outgoing messages:
the notification runner delivers events and acknowledges with --ack only after
delivery. Repeated checks retain unacknowledged events.
"""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import re
import urllib.error
import urllib.request

STATUS_URL = 'https://cosmotrak.com/api/status'


def request(url, method='GET'):
    req = urllib.request.Request(url, method=method, headers={'User-Agent': 'CosmotrakHealthMonitor/1.0'})
    try:
        return urllib.request.urlopen(req, timeout=15)
    except urllib.error.HTTPError as error:
        if error.code == 503 and url == STATUS_URL:
            return error  # A healthy reporting process can report unhealthy data.
        raise


def evaluate(data, now):
    problems = []
    if not data.get('live') or not data.get('publication'):
        return ['status_unavailable']
    def age(value):
        return (now-dt.datetime.fromisoformat(value.replace('Z','+00:00'))).total_seconds() if value else float('inf')
    if not -300 <= age(data.get('checkedAt')) < 120:
        problems.append('status_stale')
    p=data['publication']
    if p.get('failureCode') or p.get('state')=='failed': problems.append('update_failed')
    if p.get('operatorRequired'): problems.append('operator_required')
    if age(p.get('lastChecked')) > 2700: problems.append('publisher_heartbeat_missing')
    catalog_age=max(age(p.get('lastPublished')),age(p.get('satellitesUpdatedAt')))
    if catalog_age > 36*3600: problems.append('catalog_stale_critical')
    elif catalog_age > 30*3600: problems.append('catalog_stale_warning')
    if not p.get('healthy') and not problems: problems.append('data_unhealthy')
    if p.get('retryNotBefore') and p.get('failureCode') and age(p['retryNotBefore']) > 1800: problems.append('retry_overdue')
    return problems


def observe(previous):
    now=dt.datetime.now(dt.timezone.utc)
    result={'checkedAt':now.isoformat(),'problems':[]}
    try:
        with request(STATUS_URL) as response: data=json.loads(response.read(65537))
        result['problems']=evaluate(data,now)
        result['publication']=data.get('publication')
    except Exception as error:
        result['problems'].append('status_unavailable')
        result['statusError']=type(error).__name__
    try:
        download=(result.get('publication') or {}).get('download') or {}
        key=download.get('key','')
        expected=download.get('sha256','')
        if not re.fullmatch(r'Satellite_Database/satellite-database-\d{4}-\d{2}-\d{2}\.db',key):
            raise ValueError('Invalid production download identity')
        if not re.fullmatch('[a-f0-9]{64}',expected): raise ValueError('Missing verified content hash')
        url='https://cosmotrak-data.s3.us-east-1.amazonaws.com/'+key
        with request(url,'HEAD') as response:
            size=int(response.headers.get('Content-Length','0'))
            if not 0<size<=100*1024*1024: raise ValueError('Unexpected download size')
        verified=previous.get('download',{})
        last=dt.datetime.fromisoformat(verified['checkedAt']) if verified.get('checkedAt') else dt.datetime.min.replace(tzinfo=dt.timezone.utc)
        if verified.get('sha256')!=expected or now-last>dt.timedelta(hours=24):
            digest=hashlib.sha256()
            count=0
            with request(url) as response:
                while chunk:=response.read(1024*1024):
                    count+=len(chunk)
                    if count>100*1024*1024: raise ValueError('Oversized download')
                    digest.update(chunk)
            if count!=size or digest.hexdigest()!=expected: raise ValueError('Download integrity mismatch')
            verified={'key':key,'sha256':expected,'size':count,'checkedAt':now.isoformat()}
        result['download']=verified
    except Exception as error:
        result['problems'].append('download_check_failed')
        result['downloadError']=type(error).__name__
    return result


def transition(previous, result):
    signature=','.join(sorted(set(result['problems']))) or 'healthy'
    result['signature']=signature
    prior=previous.get('acknowledgedSignature')
    result['acknowledgedSignature']=prior
    if signature!=prior:
        result['event']={'type':'recovery' if signature=='healthy' else 'failure','signature':signature,
                         'message':'Satellite data recovered.' if signature=='healthy' else 'Satellite data needs attention: '+signature}
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--state',required=True,type=Path)
    parser.add_argument('--ack',help='Acknowledge an event signature after delivery')
    args=parser.parse_args()
    previous=json.loads(args.state.read_text()) if args.state.exists() else {}
    if args.ack is not None:
        if args.ack!=previous.get('signature'): raise SystemExit('Event changed; not acknowledged')
        result={**previous,'acknowledgedSignature':args.ack}
        result.pop('event',None)
    else: result=transition(previous,observe(previous))
    args.state.parent.mkdir(parents=True,exist_ok=True)
    temp=args.state.with_suffix('.tmp')
    temp.write_text(json.dumps(result,indent=2))
    temp.replace(args.state)
    print(json.dumps(result,indent=2))
