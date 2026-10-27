import re,sys
src=open("/root/mc/sql-oldest.sql").read()
m=re.search(r"^-- tag packed\n(.*?)\n(?:\n|$)", src, re.S|re.M); A=m.group(1).strip()
old_c=A[A.index("c AS MATERIALIZED"):A.index(", d AS MATERIALIZED")]
new=("w AS MATERIALIZED (SELECT r.k, ARRAY(SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.k) ORDER BY at.article_id DESC LIMIT 1000) AS ids FROM (SELECT DISTINCT k FROM q) r), "
     "c AS MATERIALIZED (SELECT w.k, cardinality(w.ids)::int8 AS n FROM w), "
     "p AS MATERIALIZED (SELECT r.l, r.o, r.k, x.id FROM (SELECT DISTINCT l, o, k FROM q) r JOIN w ON w.k = r.k CROSS JOIN LATERAL unnest(w.ids[r.o + 1 : r.o + r.l]) AS x(id))")
B=A.replace(old_c,new); assert B!=A
open("/root/mc/sql-tagw.sql","w").write("-- tag packed\n"+A+"\n\n-- tagw packed\n"+B+"\n")
