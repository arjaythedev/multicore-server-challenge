This dir only meant for debuging. Not for the real test benchmark.

The `postgres-primary` container mirrors `box/pg-conf.sh`: it starts Postgres
with the pgtune "Web application" values for the 8 vCPU / 16 GB box, including
`max_connections = 100`.
