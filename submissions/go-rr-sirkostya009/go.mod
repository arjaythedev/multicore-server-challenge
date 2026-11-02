module conduit

go 1.27.1

require (
	github.com/jackc/pgx/v5 v5.11.0
	github.com/sirkostya009/ggen v0.0.0-20261017213240-bc891b094e3a
	golang.org/x/crypto v0.58.0
	golang.org/x/sys v0.49.0
)

require (
	github.com/jackc/pgpassfile v1.0.0 // indirect
	github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 // indirect
	github.com/jackc/puddle/v2 v2.2.2 // indirect
	github.com/sirkostya009/ggen/cmd/ggen v0.0.0-20261017213240-bc891b094e3a // indirect
	github.com/sirkostya009/ggen/gen v0.0.0-20260919010519-d85535be1056 // indirect
	github.com/sirkostya009/rr v0.0.0-20261017220542-1afcb5b88e01 // indirect
	golang.org/x/mod v0.41.0 // indirect
	golang.org/x/sync v0.24.0 // indirect
	golang.org/x/text v0.43.0 // indirect
	golang.org/x/tools v0.51.0 // indirect
)

tool (
	github.com/sirkostya009/ggen/cmd/ggen
	github.com/sirkostya009/rr
)
