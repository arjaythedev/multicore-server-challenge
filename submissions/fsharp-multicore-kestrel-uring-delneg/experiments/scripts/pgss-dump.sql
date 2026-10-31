\pset format unaligned
\pset fieldsep '\t'
\pset tuples_only on
SELECT calls, round(total_exec_time::numeric,1), rows, round((total_exec_time/greatest(calls,1))::numeric,3), regexp_replace(query, '\s+', ' ', 'g') FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname='conduit') ORDER BY total_exec_time DESC;
