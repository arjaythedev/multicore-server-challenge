// Read-only SQL equivalence checks, not a load test. Build before running.
import assert from 'node:assert/strict';

assert(process.env.TEST_SQL_DATABASE_URL, 'Set TEST_SQL_DATABASE_URL explicitly');
process.env.DATABASE_URL = process.env.TEST_SQL_DATABASE_URL;
process.env.JWT_SECRET = 'sql-regression-test-only';
process.env.PG_POOL_SIZE = '1';
const { pool, issueToken } = await import('./dist/utils.js');
const { listArticles, getArticleFeed, getCurrentUser } = await import('./dist/handlers.js');
const client = await pool.connect();
const originalQuery = pool.query;
let captured = [];
// Exercise the real handlers, directing every statement into one read-only snapshot.
pool.query = async (sql, values) => {
  const result = await client.query(sql, values);
  captured.push({ sql, values, rows: result.rows });
  return result;
};
async function call(handler, query, viewer) {
  captured = [];
  let body;
  const response = {
    writeHead(status) { assert.equal(status, 200); return this; },
    end(value) { body = JSON.parse(value); },
  };
  const headers = viewer === '0' ? {} : { authorization: `Token ${await issueToken(viewer)}` };
  await handler({ request: { headers }, response, url: new URL(`http://localhost/api/articles?${query}`), params: {} });
  return body;
}
function baseline(query, viewer, feed, select) {
  const p = new URLSearchParams(query);
  const values = [viewer, Number(p.get('limit') ?? 20), Number(p.get('offset') ?? 0)];
  let where = 'TRUE';
  if (feed) where = 'a.author_id IN (SELECT followee_id FROM follows WHERE follower_id=$1)';
  else if (p.get('tag')) {
    where = 'a.id IN (SELECT at.article_id FROM article_tags at JOIN tags t ON t.id=at.tag_id WHERE t.name=$4)';
    values.push(p.get('tag'));
  } else if (p.get('author')) {
    where = 'a.author_id=(SELECT id FROM users WHERE username=$4)';
    values.push(p.get('author'));
  } else if (p.get('favorited')) {
    where = 'a.id IN (SELECT f.article_id FROM favorites f JOIN users fu ON fu.id=f.user_id WHERE fu.username=$4)';
    values.push(p.get('favorited'));
  }
  return [
    { sql: `${select} WHERE ${where} ORDER BY a.id DESC LIMIT $2 OFFSET $3`, values },
    { sql: `SELECT count(*) FROM (SELECT 1 FROM articles a WHERE ($1::bigint IS NOT NULL) AND ${where.replaceAll('$4', '$2')} LIMIT 1000) counted`,
      values: values.length === 4 ? [viewer, values[3]] : [viewer] },
  ];
}
async function explain(statement) {
  const result = await client.query(`EXPLAIN (FORMAT JSON) ${statement.sql}`, statement.values);
  const plan = result.rows[0]['QUERY PLAN'][0].Plan;
  const indexes = new Set();
  const walk = node => {
    if (node['Index Name']) indexes.add(node['Index Name']);
    for (const child of node.Plans ?? []) walk(child);
  };
  walk(plan);
  return { estimatedCost: plan['Total Cost'], indexes: [...indexes] };
}
try {
  await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
  await client.query("SET LOCAL statement_timeout='10s'");
  const tag = (await client.query('SELECT name FROM tags ORDER BY id LIMIT 1')).rows[0].name;
  const author = (await client.query('SELECT username FROM users WHERE id=(SELECT author_id FROM articles ORDER BY id LIMIT 1)')).rows[0].username;
  const favoriter = (await client.query('SELECT username FROM users WHERE id=(SELECT user_id FROM favorites ORDER BY user_id LIMIT 1)')).rows[0].username;
  const filters = [
    ['all', ''], ['tag', `tag=${encodeURIComponent(tag)}`],
    ['author', `author=${encodeURIComponent(author)}`],
    ['favorited', `favorited=${encodeURIComponent(favoriter)}`], ['feed', ''],
    ['missing-tag', 'tag=__sql_check_missing__'],
    ['missing-author', 'author=__sql_check_missing__'],
    ['missing-favoriter', 'favorited=__sql_check_missing__'],
    ['precedence', `tag=${encodeURIComponent(tag)}&author=__sql_check_missing__`],
    ['empty-tag', `tag=&author=${encodeURIComponent(author)}`],
  ];
  let checks = 0;
  for (const [name, filter] of filters) {
    for (const [limit, offset, viewer] of [[20, 0, '100'], [5, 5, '0'], [100, 1000, '100']]) {
      const feed = name === 'feed';
      const actualViewer = feed ? '100' : viewer;
      const query = `${filter}&limit=${limit}&offset=${offset}`;
      const body = await call(feed ? getArticleFeed : listArticles, query, actualViewer);
      const statements = captured.slice(-2);
      const select = statements[0].sql.slice(0, statements[0].sql.lastIndexOf('FROM articles a JOIN users u ON u.id=a.author_id')
        + 'FROM articles a JOIN users u ON u.id=a.author_id'.length);
      const old = baseline(query, actualViewer, feed, select);
      for (let i = 0; i < 2; i++) {
        const expected = await client.query(old[i].sql, old[i].values);
        assert.deepEqual(statements[i].rows, expected.rows, `${name}: statement ${i}, offset ${offset}`);
      }
      assert(body.articlesCount <= 1000);
      assert(body.articles.every(article => !Object.hasOwn(article, 'body')));
      if (offset === 0 && ['all', 'tag', 'author', 'favorited', 'feed'].includes(name)) {
        for (let i = 0; i < 2; i++) console.log(JSON.stringify({ filter: name, statement: i === 0 ? 'page' : 'count',
          before: await explain(old[i]), after: await explain(statements[i]) }));
      }
      checks++;
    }
  }
  const boundary = await call(getArticleFeed, 'limit=100&offset=2147483647', '100');
  assert.deepEqual(boundary.articles, []);
  await call(getCurrentUser, '', '100');
  assert.equal(captured.length, 1, '/api/user must issue only one SQL statement');
  await assert.rejects(call(getCurrentUser, '', '9223372036854775807'), error => error.status === 401);
  console.log(`PASS: ${checks} old/new page and count comparisons; feed int32 boundary; single-query user; unknown-user 401`);
} finally {
  pool.query = originalQuery;
  await client.query('ROLLBACK');
  client.release();
  await pool.end();
}
