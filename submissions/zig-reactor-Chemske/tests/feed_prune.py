"""Check feed rank pruning against the unpruned relation, including adversarial pages."""
import json
import os
from pathlib import Path

from support import Server, mint

work = Path(os.environ['CHALLENGE_WORK'])
submission = Path(__file__).resolve().parents[1]
results = work / 'results/feed-prune'
results.mkdir(parents=True, exist_ok=True)

with Server(results, 'feed-prune-test-only', 'feedprune', 'focus', submission/'zig-out/bin/conduit') as server:
    authors = [server.fixture('rank_author_'+str(i)) for i in range(12)]
    fans = [server.fixture('rank_viewer_'+str(i)) for i in range(6)]
    # Interleave sparse and prolific authors. Article IDs, rather than dates,
    # determine feed order. A missing rank candidate must preserve the fallback.
    for author_index, author in enumerate(authors):
        count = [0,1,2,3,5,7,11,17,31,70,260,320][author_index]
        server.sql(f"INSERT INTO articles(author_id,slug,title,description,body) SELECT {author},'rank-{author_index}-'||n,'rank','d','b' FROM generate_series(1,{count}) n ORDER BY n")
    groups = [[], authors[:8], authors, authors[8:], [authors[-1]], [authors[0], authors[1], authors[-2]]]
    for fan, followed in zip(fans, groups):
        if followed:
            server.sql(f'INSERT INTO follows(follower_id,followee_id) VALUES'+','.join(f'({fan},{a})' for a in followed))
    # Include negative IDs: the fallback is the integer type's minimum, not zero.
    server.sql(f"INSERT INTO articles(id,author_id,slug,title,description,body) VALUES(-9002,{authors[-1]},'rank-negative-2','negative','d','b'),(-9001,{authors[-1]},'rank-negative-1','negative','d','b')")

    checks = 0
    def check(fan, limit, offset):
        global checks
        expected = server.sql(f'SELECT a.slug FROM articles a WHERE a.author_id IN (SELECT followee_id FROM follows WHERE follower_id={fan}) ORDER BY a.id DESC LIMIT {limit} OFFSET {offset}').splitlines()
        count = min(1000, int(server.sql(f'SELECT count(*) FROM articles a WHERE a.author_id IN (SELECT followee_id FROM follows WHERE follower_id={fan})')))
        status, body = server.request('GET',f'/api/articles/feed?limit={limit}&offset={offset}',mint(fan,server.secret))
        assert status == 200, (fan,limit,offset,status,body)
        assert [article['slug'] for article in body['articles']] == expected, (fan,limit,offset)
        assert body['articlesCount'] == count
        checks += 1
    for fan in fans:
        for limit, offset in [(1,0),(2,1),(10,0),(10,20),(100,0),(100,250),(10,500),(100,1000),(10,100000000),(100,9223372036854775807)]:
            check(fan,limit,offset)
    # New requests must observe both relation changes and a new highest article.
    fan = fans[-1]
    server.sql(f'DELETE FROM follows WHERE follower_id={fan}')
    check(fan,10,0)
    server.sql(f'INSERT INTO follows(follower_id,followee_id) VALUES({fan},{authors[-1]})')
    server.sql(f"INSERT INTO articles(author_id,slug,title,description,body) VALUES({authors[-1]},'rank-fresh','fresh','d','b')")
    check(fan,10,0)
    (results/'results.json').write_text(json.dumps({'independent_feed_relation_checks':checks,'negative_ids':True,'deep_offset_fallback':True,'fresh_relation_changes':True},indent=2)+'\n')
    print(f'PASS: {checks} feeds match the unpruned relation; sparse authors, deep pages, negative IDs and fresh follows',flush=True)
