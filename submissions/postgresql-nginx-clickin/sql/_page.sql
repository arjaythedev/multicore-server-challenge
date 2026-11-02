-- ?limit= (1-100, default 20) and ?offset= (>= 0, default 0): plain digits, or 422.
SELECT CASE WHEN NOT (v.lim_ok AND v.off_ok) THEN 422 END AS status,
       '{"errors":{"body":["limit must be 1-100 and offset >= 0"]}}' AS body,
       CASE WHEN v.lim_ok AND v.off_ok THEN coalesce(:limit::text, '20')::int END AS page_limit,
       CASE WHEN v.lim_ok AND v.off_ok THEN coalesce(:offset::text, '0')::int END AS page_offset
  FROM (SELECT CASE WHEN :limit::text IS NULL THEN true
                    WHEN :limit::text ~ '^[0-9]{1,3}$' THEN :limit::text::int BETWEEN 1 AND 100
                    ELSE false END AS lim_ok,
               CASE WHEN :offset::text IS NULL THEN true
                    ELSE :offset::text ~ '^[0-9]{1,9}$' END AS off_ok) v
