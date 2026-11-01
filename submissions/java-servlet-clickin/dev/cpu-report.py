import re, sys, collections
t = open(sys.argv[1]).read().split("jdk.ExecutionSample")[1:]
top = collections.Counter(); incl = collections.Counter(); thr = collections.Counter()
for e in t:
    fr = [f.split("(")[0] for f in re.findall(r"^\s+([\w.$<>]+\(.*?\)) line:", e, re.M)]
    m = re.search(r'sampledThread = "([^"]+)"', e)
    if m: thr[re.sub(r"\d+", "N", m.group(1))] += 1
    if not fr: continue
    top[fr[0]] += 1
    for f in set(fr): incl[f] += 1
n = len(t); print("samples", n, dict(thr.most_common(6)))
for k, v in top.most_common(20): print("%5.1f%% %s" % (v * 100 / n, k))
print("-- inclusive (challenge.*)")
for k, v in [kv for kv in incl.most_common(80) if "challenge" in kv[0]][:25]: print("%5.1f%% %s" % (v * 100 / n, k))
