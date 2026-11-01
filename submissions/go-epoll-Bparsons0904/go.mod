module conduit

go 1.27

replace multicorelab/http => ./third_party/http

require (
	github.com/jackc/pgx/v5 v5.11.0
	golang.org/x/sys v0.49.0
	multicorelab/http v0.0.0-00010101000000-000000000000
)

require (
	github.com/jackc/pgpassfile v1.0.0 // indirect
	github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 // indirect
	golang.org/x/text v0.29.0 // indirect
)
