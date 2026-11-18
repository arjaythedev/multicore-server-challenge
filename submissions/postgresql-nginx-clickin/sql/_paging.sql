-- ?limit= (1-100, default 20) and ?offset= (>= 0, default 0) of one request row q (q.lim, q.off): plain digits,
-- or 422.
SELECT CASE WHEN NOT (v.lim_ok AND v.off_ok) THEN 422 END AS status,
       '{"errors":{"body":["limit must be 1-100 and offset >= 0"]}}' AS body,
       CASE WHEN v.lim_ok AND v.off_ok THEN coalesce(q.lim, '20')::int END AS page_limit,
       CASE WHEN v.lim_ok AND v.off_ok THEN coalesce(q.off, '0')::int END AS page_offset
  FROM (SELECT CASE WHEN q.lim IS NULL THEN true
                    WHEN q.lim ~ '^[0-9]{1,3}$' THEN q.lim::int BETWEEN 1 AND 100
                    ELSE false END AS lim_ok,
               CASE WHEN q.off IS NULL THEN true
                    ELSE q.off ~ '^[0-9]{1,9}$' END AS off_ok
        OFFSET 0) v
