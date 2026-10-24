#!/usr/bin/env python3
"""Dead-air report for a PocketDJ device, from its S3 diag logs.

Syncs s3://pocketdj-logs-623170744161/diag/<device>/ (profile llc), then reports per day:
  * the in-app DeadAirMeter numbers (`[deadair] day=… active=… dead=…` — the latest summary
    line per day, which is cumulative for that day), and
  * every measured transition (`[deadair] gap=…s from=… to=… cause=…`) by from→to pair.
Logs from builds before the meter shipped fall back to inferring transitions from
`[playback] advance from=` → `[runway] end … reason=firstAudio.*` (1 s resolution).

  scripts/deadair-report.py                      # Levi's iPhone, last 7 days
  scripts/deadair-report.py --device ios-3712BFDE --days 30
"""
import argparse, collections, datetime as dt, os, re, statistics, subprocess, sys

BUCKET = 's3://pocketdj-logs-623170744161/diag'
LINE = re.compile(r'^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) \[(\w+)\] (.*)$')
GAP = re.compile(r'gap=([\d.]+)s from=(\S+) to=(\S+) cause=(\S+)')
SUMMARY = re.compile(r'day=(\S+) active=(\d+)s dead=(\d+)s ratio=([\d.]+)% transitionDead=(\d+)s '
                     r'midSongDead=(\d+)s transitions=(\d+) gap≥3s=(\d+) gap≥10s=(\d+)')


def ts(s):
    return dt.datetime.strptime(s, '%Y-%m-%dT%H:%M:%SZ')


def pct(xs, p):
    xs = sorted(xs)
    if not xs:
        return 0.0
    k = (len(xs) - 1) * p
    lo = int(k)
    hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def launches(directory, since):
    """Yield (launch name, lines) — a launch's -p2… parts concatenated in order."""
    groups = collections.defaultdict(list)
    for f in os.listdir(directory):
        if f.endswith('.log') and f >= since:
            groups[re.sub(r'-p\d+\.log$', '.log', f)].append(f)
    part = lambda f: int(m.group(1)) if (m := re.search(r'-p(\d+)\.log$', f)) else 0
    for name in sorted(groups):
        lines = []
        for f in sorted(groups[name], key=part):
            with open(os.path.join(directory, f), errors='replace') as fh:
                lines += fh.read().splitlines()
        yield name, lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--device', default='ios-3712BFDE')
    ap.add_argument('--days', type=int, default=7)
    ap.add_argument('--dir', help='already-synced log dir (skips the S3 sync)')
    ap.add_argument('--profile', default='llc')
    a = ap.parse_args()

    directory = a.dir or os.path.join(os.environ.get('TMPDIR', '/tmp'), f'pdj-deadair-{a.device}')
    today = dt.datetime.now(dt.timezone.utc)
    since = (today - dt.timedelta(days=a.days)).strftime('%Y-%m-%d')
    if not a.dir:
        os.makedirs(directory, exist_ok=True)
        # Only the window's days: older objects migrated from the blue account can be unreadable.
        days = [(today - dt.timedelta(days=d)).strftime('%Y-%m-%d') for d in range(a.days + 1)]
        cmd = ['aws', 's3', 'sync', f'{BUCKET}/{a.device}/', directory, '--profile', a.profile,
               '--only-show-errors', '--exclude', '*'] + sum((['--include', f'{d}T*'] for d in days), [])
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            print(f'warning: s3 sync exit {r.returncode}: {r.stderr.strip().splitlines()[-1:]}', file=sys.stderr)

    summaries = {}                                  # day → latest summary tuple
    gaps = collections.defaultdict(list)            # (day, pair) → [seconds]
    inferred = collections.defaultdict(list)
    for _, lines in launches(directory, since):
        metered = any('[deadair] gap=' in ln for ln in lines)
        open_at = prev = cur = None
        for ln in lines:
            m = LINE.match(ln)
            if not m:
                continue
            when, tag, msg = ts(m.group(1)), m.group(2), m.group(3)
            day = when.strftime('%Y-%m-%d')
            if tag == 'deadair':
                if s := SUMMARY.search(msg):
                    summaries[s.group(1)] = s.groups()
                elif g := GAP.search(msg):
                    cause = g.group(4)
                    pair = f'{g.group(2)}→{g.group(3)}' + ('' if cause == 'advance' else f' ({cause})')
                    gaps[(day, pair)].append(float(g.group(1)))
            elif not metered:
                if tag == 'playback' and msg.startswith('advance from=') and open_at is None:
                    open_at, prev = when, cur
                elif tag == 'playback' and msg.startswith('track start '):
                    cur = re.search(r'backend=(\w+)', msg).group(1)
                elif tag == 'runway' and 'reason=firstAudio' in msg and open_at is not None:
                    gap = (when - open_at).total_seconds()
                    if gap <= 180:
                        inferred[(open_at.strftime('%Y-%m-%d'), f'{prev or "?"}→{cur or "?"}')].append(gap)
                    open_at = None

    if summaries:
        print('DAY         ACTIVE   DEAD  RATIO  TRANS-DEAD  MIDSONG  TRANSITIONS  ≥3s  ≥10s')
        for day in sorted(summaries):
            _, act, dead, ratio, tdead, mdead, n, g3, g10 = summaries[day]
            print(f'{day}  {int(act)/60:6.0f}m {int(dead):5}s {float(ratio):5.2f}%  {int(tdead):9}s '
                  f'{int(mdead):7}s  {int(n):11}  {int(g3):3}  {int(g10):4}')
        print()

    for title, table in (('MEASURED transitions (DeadAirMeter, ms precision)', gaps),
                         ('INFERRED transitions (pre-meter builds, 1 s resolution)', inferred)):
        if not table:
            continue
        by_pair = collections.defaultdict(list)
        for (_, pair), xs in table.items():
            by_pair[pair] += xs
        total = sum(sum(xs) for xs in by_pair.values())
        n = sum(len(xs) for xs in by_pair.values())
        print(f'{title}: {n} transitions, {total:.0f}s dead')
        print(f"  {'from→to':34} {'n':>4} {'med':>5} {'p90':>5} {'max':>5} {'≥3s':>4} {'dead':>6}")
        for pair, xs in sorted(by_pair.items(), key=lambda kv: -sum(kv[1])):
            print(f'  {pair:34} {len(xs):4} {statistics.median(xs):5.1f} {pct(xs, .9):5.1f} '
                  f'{max(xs):5.0f} {sum(1 for x in xs if x >= 3):4} {sum(xs):5.0f}s')
        print()
    if not (summaries or gaps or inferred):
        print(f'no playback in {directory} since {since}', file=sys.stderr)


if __name__ == '__main__':
    main()
