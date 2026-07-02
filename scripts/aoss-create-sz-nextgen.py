#!/usr/bin/env python3
"""Stand up a TRUE scale-to-zero OpenSearch Serverless collection for A/B testing,
leaving the prod pocketdj-search collection + policies UNTOUCHED.

Scale-to-zero (idle -> 0 OCU) requires a **NextGen collection group with min-OCU 0**.
The released aws-cli/boto3 (botocore 1.42.x) CANNOT express this: it has no `generation`
param and a stale client-side `min>=1` on capacityLimits; UpdateCollectionGroup rejects
min-0 service-side too. min-0 is only accepted at CreateCollectionGroup with
generation=NEXTGEN via a RAW signed control-plane call — which this script makes.
Everything else (policies, collection) goes through the normal SDK.

Verified 2026-07-02: group idles to 0 OCU ~10 min after last request; ~16.6s cold-start
on first query after idle; per-group OCU under AWS/AOSS SearchOCU/IndexingOCU dimensioned
by CollectionGroupName. Idempotent-ish. Run in the background (it sleeps on transitions).

Steps: net policy -> data policy -> NextGen group (raw, min-0) -> collection -> wait ACTIVE.
Then load with:  node scripts/es-index.mjs --endpoint $(cat .aoss-sz-endpoint.txt) --index pocketdj \
                      --sources public/current-index.json,public/apple-music-index.json,public/digital-index.json
"""
import sys, time, json
import botocore.session
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.httpsession import URLLib3Session

REGION = 'us-west-2'
ACCT = '011183829623'
GROUP = 'pocketdj-sz-grp'
COLL = 'pocketdj-sz'
NETPOL = 'pocketdj-sz-net'
DATAPOL = 'pocketdj-sz-data'
ENDPOINT_FILE = __file__.rsplit('/', 2)[0] + '/.aoss-sz-endpoint.txt'

sess = botocore.session.Session(profile='levi')
oss = sess.create_client('opensearchserverless', region_name=REGION)
creds = sess.get_credentials().get_frozen_credentials()


def log(*a): print('[sz-nextgen]', *a, flush=True)


def raw(target, payload):
    """Raw SigV4-signed control-plane call (bypasses the SDK model for generation/min-0)."""
    body = json.dumps(payload)
    req = AWSRequest(method='POST', url=f'https://aoss.{REGION}.amazonaws.com', data=body,
                     headers={'Content-Type': 'application/x-amz-json-1.0',
                              'X-Amz-Target': f'OpenSearchServerless.{target}'})
    SigV4Auth(creds, 'aoss', REGION).add_auth(req)
    r = URLLib3Session().send(req.prepare())
    return r.status_code, r.content.decode('utf8', 'replace')


def coll_detail():
    cd = oss.batch_get_collection(names=[COLL]).get('collectionDetails', [])
    return cd[0] if cd else None


def group_detail():
    gd = oss.batch_get_collection_group(names=[GROUP]).get('collectionGroupDetails', [])
    return gd[0] if gd else None


# 1) network policy (public, scoped to pocketdj-sz only)
try:
    oss.get_security_policy(name=NETPOL, type='network'); log(f'net policy {NETPOL} exists')
except oss.exceptions.ResourceNotFoundException:
    log(f'creating net policy {NETPOL}')
    oss.create_security_policy(name=NETPOL, type='network', policy=json.dumps(
        [{"Rules": [{"Resource": [f"collection/{COLL}"], "ResourceType": "collection"},
                    {"Resource": [f"collection/{COLL}"], "ResourceType": "dashboard"}],
          "AllowFromPublic": True}]))

# 2) data access policy (Developer full + djpocketsearch read)
try:
    oss.get_access_policy(name=DATAPOL, type='data'); log(f'data policy {DATAPOL} exists')
except oss.exceptions.ResourceNotFoundException:
    log(f'creating data policy {DATAPOL}')
    oss.create_access_policy(name=DATAPOL, type='data', policy=json.dumps([
        {"Rules": [{"Resource": [f"index/{COLL}/*"], "Permission": ["aoss:*"], "ResourceType": "index"},
                   {"Resource": [f"collection/{COLL}"], "Permission": ["aoss:*"], "ResourceType": "collection"}],
         "Principal": [f"arn:aws:iam::{ACCT}:user/Developer"], "Description": "AB test admin"},
        {"Rules": [{"Resource": [f"index/{COLL}/*"], "Permission": ["aoss:ReadDocument", "aoss:DescribeIndex"],
                    "ResourceType": "index"}],
         "Principal": [f"arn:aws:iam::{ACCT}:user/djpocketsearch"], "Description": "AB test read-only"}]))

# 3) NextGen group with min-OCU 0 (RAW — the SDK/CLI can't do this)
if group_detail():
    log(f'group {GROUP} exists')
else:
    log('creating NextGen group (generation=NEXTGEN, min-OCU 0, standby ENABLED, max 8) via raw API')
    s, b = raw('CreateCollectionGroup', {
        'name': GROUP, 'standbyReplicas': 'ENABLED', 'generation': 'NEXTGEN',
        'description': 'PocketDJ scale-to-zero A/B group (min-OCU 0)',
        'capacityLimits': {'minIndexingCapacityInOCU': 0, 'minSearchCapacityInOCU': 0,
                           'maxIndexingCapacityInOCU': 8, 'maxSearchCapacityInOCU': 8}})
    if s != 200:
        log('CreateCollectionGroup FAILED:', s, b); sys.exit(1)
    log('group created; capacityLimits =', json.dumps(json.loads(b)['createCollectionGroupDetail']['capacityLimits']))

# 4) collection in the group
if coll_detail():
    log(f'collection {COLL} exists')
else:
    log(f'creating collection {COLL} (SEARCH, standby ENABLED) in {GROUP}')
    oss.create_collection(name=COLL, type='SEARCH', standbyReplicas='ENABLED',
                          collectionGroupName=GROUP,
                          description='PocketDJ scale-to-zero A/B test collection',
                          encryptionConfig={'aWSOwnedKey': True})

# 5) wait ACTIVE, save endpoint
for _ in range(60):
    cur = coll_detail(); st = cur['status'] if cur else 'NONE'
    if st == 'ACTIVE':
        ep = cur['collectionEndpoint']
        log('ACTIVE ✓  endpoint:', ep)
        open(ENDPOINT_FILE, 'w').write(ep + '\n')
        log('endpoint saved to', ENDPOINT_FILE)
        sys.exit(0)
    log(f'  status={st} — waiting'); time.sleep(10)
log('timed out waiting for ACTIVE'); sys.exit(1)
