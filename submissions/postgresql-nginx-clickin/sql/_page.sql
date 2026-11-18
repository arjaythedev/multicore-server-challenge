-- ?limit= and ?offset= of one request, checked by _paging.sql.
SELECT x.status, x.body, x.page_limit, x.page_offset
  FROM (SELECT :limit::text AS lim, :offset::text AS off) q CROSS JOIN LATERAL ({{_paging}}) x
