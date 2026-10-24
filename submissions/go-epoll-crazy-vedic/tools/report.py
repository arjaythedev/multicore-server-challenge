#!/usr/bin/env python3
"""Summarize one local measurement, including stage-counter differences."""
import csv
import datetime
import json
from pathlib import Path
import statistics
import sys

p = Path(sys.argv[1])
load = json.loads((p / 'merged.json').read_text())
begin = load['start_at_ms']/1000 + load['ramp_s']
end = begin + load['measure_s']
rows = [{k: float(v) for k,v in r.items()} for r in csv.DictReader((p/'monitor.csv').open())]
rows = [r for r in rows if begin <= r['unix_s'] <= end]
resource = {k: {'mean': statistics.mean(r[k] for r in rows), 'peak': max(r[k] for r in rows)} for k in rows[0] if k != 'unix_s'}
snapshots = []
for line in (p/'server.log').read_text().splitlines():
    if '"type":"stats"' not in line:
        continue
    stamp = datetime.datetime.strptime(line[:19],'%Y/%m/%d %H:%M:%S').astimezone().timestamp()
    if begin <= stamp <= end:
        snapshots.append(json.loads(line[20:]))
a,b = snapshots[0],snapshots[-1]
def distribution(old,new):
    count = new['count'] - old['count']
    buckets = [n-o for o,n in zip(old['buckets_pow2'],new['buckets_pow2'])]
    result = {'count': count, 'mean': (new['sum']-old['sum'])/max(1,count)}
    for quantile in (.5,.95,.99):
        seen = 0
        for i,n in enumerate(buckets):
            seen += n
            if seen >= count*quantile:
                result['p'+str(round(quantile*100))+'_upper_bound'] = 2**i if i<31 else None
                break
    return result
result = {'overall':load['overall'],'resources':resource,'config':json.loads((p/'config.json').read_text())}
jobs = b['jobs']-a['jobs']; batches = b['batches']-a['batches']; executions = b['executions']-a['executions']
result['database'] = {'jobs':jobs,'executions':executions,'jobs_per_flight':jobs/max(1,batches),'execution_reduction_fraction':1-executions/max(1,jobs)}
result['stages'] = {
    k: distribution(a['stages'][k],v) if isinstance(v,dict) and 'buckets_pow2' in v
    else v-a['stages'][k]
    for k,v in b.get('stages',{}).items() if k in a.get('stages',{})
}
result['statements'] = {}
for k,v in b.get('statements',{}).items():
    old = a.get('statements',{}).get(k)
    if not old: continue
    result['statements'][k] = {n:v[n]-old[n] for n in ['jobs','executions','shared_jobs']}
    for n in ['first_result_wait_ns','result_drain_ns']:
        result['statements'][k][n] = distribution(old[n],v[n])
result['endpoints'] = {r['name']:{k:r[k] for k in ['count','p50_ms','p95_ms','p99_ms','errors']} for r in load['endpoints']}
(p/'report.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:result[k] for k in ['overall','resources','database']},indent=2))
