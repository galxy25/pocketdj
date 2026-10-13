#!/usr/bin/env python3
"""Create the GREEN OpenSearch Serverless collection `pocketdj-search` as a NextGen, scale-to-zero
(min-OCU 0) collection, mirroring blue's pocketdj-search-grp (standby ENABLED, max 8/8 OCU).

Same raw-call trick as scripts/aoss-create-sz-nextgen.py: min-OCU 0 + generation=NEXTGEN is only
accepted by a raw SigV4 CreateCollectionGroup. Policies come from scripts/green/blue-snapshot/aoss
with blue's principals mapped to green (Developer -> green admin user `levi`). Idempotent.
Profile: llc (623170744161). Never llc-projects.
"""
import json, os, sys, time
import botocore.session
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.httpsession import URLLib3Session

REGION = 'us-west-2'
GA, BA = '623170744161', '011183829623'
PROFILE = os.environ.get('GREEN_PROFILE', 'llc')
assert PROFILE != 'llc-projects'
GROUP, COLL, NETPOL, DATAPOL = 'pocketdj-search-grp', 'pocketdj-search', 'pocketdj-net', 'pocketdj-data'
SNAP = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'blue-snapshot', 'aoss')

sess = botocore.session.Session(profile=PROFILE)
oss = sess.create_client('opensearchserverless', region_name=REGION)
creds = sess.get_credentials().get_frozen_credentials()
acct = sess.create_client('sts', region_name=REGION).get_caller_identity()['Account']
assert acct == GA, f'profile {PROFILE} is account {acct}, expected {GA}'


def log(*a): print('[green-aoss]', *a, flush=True)


def to_green(text):
    return (text.replace(f'arn:aws:iam::{BA}:user/Developer', f'arn:aws:iam::{GA}:user/levi')
                .replace(BA, GA))


def raw(target, payload):
    req = AWSRequest(method='POST', url=f'https://aoss.{REGION}.amazonaws.com', data=json.dumps(payload),
                     headers={'Content-Type': 'application/x-amz-json-1.0',
                              'X-Amz-Target': f'OpenSearchServerless.{target}'})
    SigV4Auth(creds, 'aoss', REGION).add_auth(req)
    r = URLLib3Session().send(req.prepare())
    return r.status_code, r.content.decode('utf8', 'replace')


net = to_green(open(f'{SNAP}/net.json').read())
data = to_green(open(f'{SNAP}/data.json').read())

try:
    cur = oss.get_security_policy(name=NETPOL, type='network')['securityPolicyDetail']
    if cur['policy'] != json.loads(net):
        oss.update_security_policy(name=NETPOL, type='network', policyVersion=cur['policyVersion'], policy=json.dumps(json.loads(net)))
        log('net policy updated')
    else:
        log('net policy unchanged')
except oss.exceptions.ResourceNotFoundException:
    oss.create_security_policy(name=NETPOL, type='network', policy=json.dumps(json.loads(net))); log('net policy created')

try:
    cur = oss.get_access_policy(name=DATAPOL, type='data')['accessPolicyDetail']
    if cur['policy'] != json.loads(data):
        oss.update_access_policy(name=DATAPOL, type='data', policyVersion=cur['policyVersion'], policy=json.dumps(json.loads(data)))
        log('data policy updated')
    else:
        log('data policy unchanged')
except oss.exceptions.ResourceNotFoundException:
    oss.create_access_policy(name=DATAPOL, type='data', policy=json.dumps(json.loads(data))); log('data policy created')

if oss.batch_get_collection_group(names=[GROUP]).get('collectionGroupDetails'):
    log(f'group {GROUP} exists')
else:
    s, b = raw('CreateCollectionGroup', {
        'name': GROUP, 'standbyReplicas': 'ENABLED', 'generation': 'NEXTGEN',
        'description': 'PocketDJ prod scale-to-zero group',
        'capacityLimits': {'minIndexingCapacityInOCU': 0, 'minSearchCapacityInOCU': 0,
                           'maxIndexingCapacityInOCU': 8, 'maxSearchCapacityInOCU': 8}})
    if s != 200:
        log('CreateCollectionGroup FAILED', s, b); sys.exit(1)
    log('group created', json.loads(b)['createCollectionGroupDetail']['capacityLimits'])

meta = json.load(open(f'{SNAP}/collection.json'))
if not oss.batch_get_collection(names=[COLL]).get('collectionDetails'):
    oss.create_collection(name=COLL, type=meta['type'], standbyReplicas=meta['standbyReplicas'],
                          collectionGroupName=GROUP, description=meta['description'],
                          encryptionConfig={'aWSOwnedKey': True})
    log('collection create requested')

for _ in range(90):
    cd = oss.batch_get_collection(names=[COLL])['collectionDetails'][0]
    if cd['status'] == 'ACTIVE':
        log('ACTIVE', cd['collectionEndpoint']); sys.exit(0)
    if cd['status'] == 'FAILED':
        log('FAILED', cd); sys.exit(1)
    log('status', cd['status']); time.sleep(10)
log('timed out'); sys.exit(1)
