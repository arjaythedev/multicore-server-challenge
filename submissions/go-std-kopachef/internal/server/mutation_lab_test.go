package server

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func mutationProcessCPU() int64 {
	var usage syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &usage); err != nil {
		panic(err)
	}
	return (usage.Utime.Sec+usage.Stime.Sec)*1e6 + usage.Utime.Usec + usage.Stime.Usec
}

func mutationPostgresCPU(tb testing.TB) int64 {
	tb.Helper()
	output, err := exec.Command("docker", "exec", "multicore-challenge-pg", "cat", "/sys/fs/cgroup/cpu.stat").Output()
	if err != nil {
		tb.Fatal(err)
	}
	fields := strings.Fields(string(output))
	for i := 0; i+1 < len(fields); i += 2 {
		if fields[i] == "usage_usec" {
			value, err := strconv.ParseInt(fields[i+1], 10, 64)
			if err != nil {
				tb.Fatal(err)
			}
			return value
		}
	}
	tb.Fatal("missing PostgreSQL CPU counter")
	return 0
}

type walCounters struct{ syncs, milliseconds float64 }

func mutationWAL(tb testing.TB, pool *pgxpool.Pool) walCounters {
	tb.Helper()
	ctx := context.Background()
	connections := pool.AcquireAllIdle(ctx)
	for _, connection := range connections {
		_, err := connection.Exec(ctx, "SELECT pg_stat_force_next_flush()")
		connection.Release()
		if err != nil {
			tb.Fatal(err)
		}
	}
	var result walCounters
	if err := pool.QueryRow(ctx, `SELECT coalesce(sum(fsyncs),0), coalesce(sum(fsync_time),0)
 FROM pg_stat_io WHERE object = 'wal'`).Scan(&result.syncs, &result.milliseconds); err != nil {
		tb.Fatal(err)
	}
	return result
}

// An already-arrived cohort gives an upper bound on batching benefit. Actual
// queue collection, conflicting requests and error fallback are not timed here.
func BenchmarkMutationCohorts(b *testing.B) {
	for _, size := range []int{1, 4, 16} {
		for _, mode := range []string{"parallel", "transaction", "array"} {
			b.Run(fmt.Sprintf("jobs%d/%s", size, mode), func(b *testing.B) {
				f := newReadFixture(b, 0)
				ctx := context.Background()
				rows, err := f.pool.Query(ctx, `INSERT INTO articles(slug,author_id,title,description,body)
 SELECT $1 || '_mutation_' || i, $2, 'title', 'description', 'body'
 FROM generate_series(1,$3::int) i RETURNING id`, f.cases[0].slug, f.authorID, size)
				if err != nil {
					b.Fatal(err)
				}
				ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
				if err != nil {
					b.Fatal(err)
				}
				warm := make([]*pgxpool.Conn, size)
				for i := range warm {
					warm[i], err = f.pool.Acquire(ctx)
					if err != nil {
						b.Fatal(err)
					}
				}
				for _, c := range warm {
					c.Release()
				}
				beforeWAL := mutationWAL(b, f.pool)
				beforePG, beforeGo := mutationPostgresCPU(b), mutationProcessCPU()
				iteration := 0
				for b.Loop() {
					insert := iteration%2 == 0
					iteration++
					query := `DELETE FROM favorites WHERE user_id=$1 AND article_id=$2`
					if insert {
						query = `INSERT INTO favorites(user_id,article_id) VALUES($1,$2) ON CONFLICT DO NOTHING`
					}
					switch mode {
					case "parallel":
						var wg sync.WaitGroup
						for _, id := range ids {
							wg.Add(1)
							go func() {
								defer wg.Done()
								if _, err := f.pool.Exec(ctx, query, f.readerID, id); err != nil {
									b.Error(err)
								}
							}()
						}
						wg.Wait()
					case "transaction":
						var batch pgx.Batch
						for _, id := range ids {
							batch.Queue(query, f.readerID, id)
						}
						if err := f.pool.SendBatch(ctx, &batch).Close(); err != nil {
							b.Fatal(err)
						}
					case "array":
						query = `DELETE FROM favorites WHERE user_id=$1 AND article_id=ANY($2::bigint[])`
						if insert {
							query = `INSERT INTO favorites(user_id,article_id) SELECT $1,unnest($2::bigint[]) ON CONFLICT DO NOTHING`
						}
						if _, err := f.pool.Exec(ctx, query, f.readerID, ids); err != nil {
							b.Fatal(err)
						}
					}
				}
				afterGo, afterPG := mutationProcessCPU(), mutationPostgresCPU(b)
				afterWAL := mutationWAL(b, f.pool)
				operations := float64(b.N * size)
				b.ReportMetric(float64(afterGo-beforeGo)/operations, "go-us/write")
				b.ReportMetric(float64(afterPG-beforePG)/operations, "pg-us/write")
				b.ReportMetric((afterWAL.syncs-beforeWAL.syncs)/operations, "fsyncs/write")
				b.ReportMetric((afterWAL.milliseconds-beforeWAL.milliseconds)/operations, "fsync-ms/write")
				// Check visibility from a different backend after the batch returns.
				configuration, err := pgxpool.ParseConfig(os.Getenv("TEST_DATABASE_URL"))
				if err != nil {
					b.Fatal(err)
				}
				connection, err := pgx.ConnectConfig(ctx, configuration.ConnConfig.Copy())
				if err != nil {
					b.Fatal(err)
				}
				defer connection.Close(ctx)
				var count int
				if err := connection.QueryRow(ctx, `SELECT count(*) FROM favorites WHERE user_id=$1 AND article_id=ANY($2::bigint[])`, f.readerID, ids).Scan(&count); err != nil {
					b.Fatal(err)
				}
				want := 0
				if iteration%2 == 1 {
					want = size
				}
				if count != want {
					b.Fatalf("committed favorites=%d, want %d", count, want)
				}
			})
		}
	}
}
