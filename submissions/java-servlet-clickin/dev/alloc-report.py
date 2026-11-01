import re, sys, collections
txt = open(sys.argv[1]).read()
cls = collections.Counter(); site = collections.Counter()
unit = {"bytes": 1, "byte": 1, "kB": 1e3, "MB": 1e6, "GB": 1e9}
for e in txt.split("jdk.ObjectAllocationSample")[1:]:
    m = re.search(r"objectClass = (\S+)", e); w = re.search(r"weight = ([\d.]+) (\w+)", e)
    if not m or not w: continue
    v = float(w.group(1)) * unit.get(w.group(2), 1)
    fr = [f.split("(")[0].split(".") for f in re.findall(r"^\s+([\w.$<>]+\(.*?\)) line:", e, re.M)[:4]]
    cls[m.group(1)] += v; site[" <- ".join(f[-2] + "." + f[-1] for f in fr)] += v
tot = sum(cls.values()); print("total MB %.0f" % (tot / 1e6))
for k, v in cls.most_common(10): print("%5.1f%% %s" % (v / tot * 100, k))
print()
for k, v in site.most_common(18): print("%5.1f%% %s" % (v / tot * 100, k))
