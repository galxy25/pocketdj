#!/usr/bin/env python3
"""Swap prod `pocketdj-search` from the classic 1.0-OCU-floor collection to a NextGen
scale-to-zero collection WITH THE SAME NAME.

Sequence (downtime between delete and reload — OK for alpha):
  1. delete the old `pocketdj-search` collection (its network/data policies are kept —
     they're scoped to the name, so they auto-apply to the recreated collection).
  2. create a NextGen group `pocketdj-search-grp` (min-OCU 0) via raw control-plane call
     (the SDK/CLI can't express generation=NEXTGEN / min-0).
  3. LOOP creating a collection named `pocketdj-search` in that group until the name frees
     (aoss reserves a deleted name for a while) — the user asked to wait/loop for this.
  4. wait ACTIVE, save endpoint to .aoss-prod-endpoint.txt.

NOTE: same NAME does NOT mean same endpoint host — aoss derives the host from a new
server-assigned id. The clients pick up the new host from public/search-config.json.

Run in the BACKGROUND (it sleeps through deletes / name-release / provisioning).
"""
import sys, time, json
import botocore.session
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.httpsession import URLLib3Session

REGION = 'us-west-2'
NAME = 'pocketdj-search'
GROUP = 'pocketdj-search-grp'
ENDPOINT_FILE = __file__.rsplit('/', 2)[0] + '/.aoss-prod-endpoint.txt'

sess = botocore.session.Session(profile='levi')
oss = sess.create_client('opensearchserverless', region_name=REGION)
creds = sess.get_credentials().get_frozen_credentials()


def log(*a): print('[swap-prod]', *a, flush=True)


def raw(target, payload):
    body = json.dumps(payload)
    req = AWSRequest(method='POST', url=f'https://aoss.{REGION}.amazonaws.com', data=body,
                     headers={'Content-Type': 'application/x-amz-json-1.0',
                              'X-Amz-Target': f'OpenSearchServerless.{target}'})
    SigV4Auth(creds, 'aoss', REGION).add_auth(req)
    r = URLLib3Session().send(req.prepare())
    return r.status_code, r.content.decode('utf8', 'replace')


def coll_detail(name):
    cd = oss.batch_get_collection(names=[name]).get('collectionDetails', [])
    return cd[0] if cd else None


def group_exists():
    return bool(oss.batch_get_collection_group(names=[GROUP]).get('collectionGroupDetails', []))


# 1) delete old pocketdj-search
old = coll_detail(NAME)
if old:
    log(f"deleting OLD {NAME} id={old['id']} (status={old['status']})  -- prod search DOWN from here")
    try:
        oss.delete_collection(id=old['id'])
    except Exception as e:
        log("delete error (maybe already deleting):", str(e)[:200])
    for _ in range(120):
        if not coll_detail(NAME):
            log("old collection deleted ✓"); break
        log("  still deleting — waiting"); time.sleep(10)
else:
    log(f"no existing {NAME} — nothing to delete")

# 2) NextGen group with min-OCU 0 (raw; SDK can't)
if group_exists():
    log(f"group {GROUP} exists")
else:
    log(f"creating NextGen group {GROUP} (generation=NEXTGEN, min-OCU 0, standby ENABLED, max 8)")
    s, b = raw('CreateCollectionGroup', {
        'name': GROUP, 'standbyReplicas': 'ENABLED', 'generation': 'NEXTGEN',
        'description': 'PocketDJ prod scale-to-zero group',
        'capacityLimits': {'minIndexingCapacityInOCU': 0, 'minSearchCapacityInOCU': 0,
                           'maxIndexingCapacityInOCU': 8, 'maxSearchCapacityInOCU': 8}})
    if s != 200:
        log("CreateCollectionGroup FAILED:", s, b); sys.exit(1)
    log("group created:", json.loads(b)['createCollectionGroupDetail']['capacityLimits'])

# 3) LOOP create collection with the SAME name until it succeeds (name may be reserved briefly)
created = False
for attempt in range(1, 241):  # up to ~60 min at 15s
    if coll_detail(NAME):
        log(f"{NAME} now exists (created)"); created = True; break
    try:
        oss.create_collection(name=NAME, type='SEARCH', standbyReplicas='ENABLED',
                              collectionGroupName=GROUP,
                              description='PocketDJ prod search (NextGen scale-to-zero)',
                              encryptionConfig={'aWSOwnedKey': True})
        log(f"create accepted on attempt {attempt}"); created = True; break
    except Exception as e:
        msg = str(e)
        if 'ConflictException' in type(e).__name__ or 'already' in msg.lower() or 'in use' in msg.lower() or 'exists' in msg.lower():
            log(f"  attempt {attempt}: name not free yet — waiting 15s ({msg[:120]})")
            time.sleep(15); continue
        log("create failed (non-retryable):", type(e).__name__, msg[:300]); sys.exit(1)
if not created:
    log("gave up waiting for the name to free"); sys.exit(1)

# 4) wait ACTIVE, save endpoint
for _ in range(60):
    cur = coll_detail(NAME); st = cur['status'] if cur else 'NONE'
    if st == 'ACTIVE':
        ep = cur['collectionEndpoint']
        log("ACTIVE ✓  NEW endpoint:", ep)
        open(ENDPOINT_FILE, 'w').write(ep + '\n')
        log("saved new endpoint ->", ENDPOINT_FILE)
        sys.exit(0)
    log(f"  status={st} — waiting"); time.sleep(10)
log("timed out waiting for ACTIVE"); sys.exit(1)
