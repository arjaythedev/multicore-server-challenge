//! Integration tests against a real PostgreSQL (`#[ignore]` by default).
//!
//! Run with `cargo test --lib pg:: -- --ignored --test-threads=1`. The target is `PG_TEST_URL`, default
//! `postgres://conduit:conduit@127.0.0.1:5433/pg_agent_test`: a copy of the seed database made with
//! `CREATE DATABASE pg_agent_test TEMPLATE conduit_dev OWNER conduit`. Tests that write clean up after themselves.

use std::time::{Duration, Instant};

use super::*;

const DEFAULT_URL: &str = "postgres://conduit:conduit@127.0.0.1:5433/pg_agent_test";
const OPTIONS: &str =
    "-c plan_cache_mode=force_generic_plan -c jit=off -c max_parallel_workers_per_gather=0";

fn config() -> Config {
    Config::from_url(&std::env::var("PG_TEST_URL").unwrap_or_else(|_| DEFAULT_URL.to_owned()))
        .unwrap()
}

fn connect() -> Connection {
    Connection::connect(&config(), OPTIONS).unwrap()
}

/// Pushes one statement per entry and flushes; every statement is expected to succeed.
fn run_one(conn: &mut Connection, stmt: &Stmt, params: &[Param<'_>], results: &mut Results) {
    conn.push(stmt, params).unwrap();
    conn.flush_and_collect(results).unwrap();
    assert!(
        results.statement(0).is_ok(),
        "{:?}",
        results.statement(0).error()
    );
}

#[test]
#[ignore]
fn connect_scram_and_session_options() {
    let mut conn = connect();
    let stmt = conn
        .prepare(
            "opts",
            "select current_setting('jit'), current_setting('plan_cache_mode'), 1::int4",
            &[],
        )
        .unwrap();
    let mut results = Results::new();
    run_one(&mut conn, &stmt, &[], &mut results);
    let row = results.statement(0).row(0).unwrap();
    assert_eq!(
        (
            row.str(0).unwrap(),
            row.str(1).unwrap(),
            row.i32(2).unwrap()
        ),
        ("off", "force_generic_plan", 1)
    );
    assert!(!conn.is_poisoned());
}

#[test]
#[ignore]
fn wrong_password_is_a_server_error() {
    let mut cfg = config();
    cfg.password = Some("not-the-password".into());
    match Connection::connect(&cfg, "") {
        Err(PgError::Server(e)) => assert_eq!(e.sqlstate_str(), "28P01"),
        Err(PgError::Auth(_)) => {}
        other => panic!("unexpected {:?}", other.err()),
    }
}

#[test]
#[ignore]
fn pipeline_of_50_mixed_statements() {
    let mut conn = connect();
    let ids = conn
        .prepare(
            "ids",
            "select id from unnest($1::int8[]) as id order by id desc",
            &[INT8_ARRAY],
        )
        .unwrap();
    let names = conn
        .prepare(
            "names",
            "select username from users where username = any($1::text[]) order by username",
            &[TEXT_ARRAY],
        )
        .unwrap();
    let scalars = conn
        .prepare(
            "scalars",
            "select $1::bool, $2::int4, $3::int8, $4::text, $5::text",
            &[BOOL, INT4, INT8, TEXT, TEXT],
        )
        .unwrap();
    let times = conn
        .prepare(
            "times",
            "select created_at, ((extract(epoch from created_at) * 1000000)::int8 - 946684800000000), \
             array(select name from tags order by id limit 3), array(select id from articles order by id limit 3) \
             from users order by id limit 1",
            &[],
        )
        .unwrap();
    let first_users = conn
        .prepare(
            "first_users",
            "select username from users order by id limit 3",
            &[],
        )
        .unwrap();
    let mut results = Results::new();
    run_one(&mut conn, &first_users, &[], &mut results);
    let known: Vec<String> = results
        .statement(0)
        .rows()
        .map(|r| r.str(0).unwrap().to_owned())
        .collect();
    assert_eq!(known.len(), 3);
    let known_refs: Vec<&str> = known.iter().map(String::as_str).collect();
    let mut wanted = known_refs.clone();
    wanted.push("no such user");
    wanted.sort_unstable();
    let mut expected_names = known_refs.clone();
    expected_names.sort_unstable();

    const COUNT: usize = 50;
    let numbers = [5_i64, -3, 9_000_000_000, 0];
    for i in 0..COUNT {
        match i % 5 {
            0 => conn.push(&ids, &[Param::Int8Array(&numbers)]).unwrap(),
            1 => conn.push(&names, &[Param::TextArray(&wanted)]).unwrap(),
            2 => conn
                .push(
                    &scalars,
                    &[
                        Param::Bool(i % 2 == 0),
                        Param::Int4(-7),
                        Param::Int8(i as i64),
                        Param::Text("åäö"),
                        Param::Null,
                    ],
                )
                .unwrap(),
            3 => conn.push(&times, &[]).unwrap(),
            _ => conn.push(&ids, &[Param::Int8Array(&[])]).unwrap(),
        }
    }
    assert_eq!(conn.pending(), COUNT);
    conn.flush_and_collect(&mut results).unwrap();
    assert_eq!(results.len(), COUNT);
    for (i, st) in results.iter().enumerate() {
        assert!(st.is_ok(), "statement {i}: {:?}", st.error());
        match i % 5 {
            0 => {
                let got: Vec<i64> = st.rows().map(|r| r.i64(0).unwrap()).collect();
                assert_eq!(got, [9_000_000_000, 5, 0, -3]);
            }
            1 => {
                let got: Vec<&str> = st.rows().map(|r| r.str(0).unwrap()).collect();
                assert_eq!(got, expected_names);
            }
            2 => {
                let row = st.row(0).unwrap();
                assert_eq!(row.bool(0).unwrap(), i % 2 == 0);
                assert_eq!(
                    (
                        row.i32(1).unwrap(),
                        row.i64(2).unwrap(),
                        row.str(3).unwrap()
                    ),
                    (-7, i as i64, "åäö")
                );
                assert!(row.is_null(4));
                assert!(row.str(4).is_err());
            }
            3 => {
                let row = st.row(0).unwrap();
                assert_eq!(row.timestamptz_micros(0).unwrap(), row.i64(1).unwrap());
                assert_eq!(row.text_array(2).unwrap().count(), 3);
                let ids: Vec<i64> = row.i64_array(3).unwrap().collect();
                assert_eq!(ids.len(), 3);
                assert!(ids.windows(2).all(|w| w[0] < w[1]));
            }
            _ => assert_eq!(st.row_count(), 0),
        }
    }
}

#[test]
#[ignore]
fn failing_statement_skips_the_rest_and_connection_survives() {
    let mut conn = connect();
    let one = conn.prepare("one", "select 1::int8", &[]).unwrap();
    let existing = conn
        .prepare(
            "existing",
            "select username, email from users order by id limit 1",
            &[],
        )
        .unwrap();
    let insert = conn
        .prepare(
            "ins",
            "insert into users (username, email, password_hash) values ($1, $2, 'x')",
            &[TEXT, TEXT],
        )
        .unwrap();
    let mut results = Results::new();
    run_one(&mut conn, &existing, &[], &mut results);
    let (username, email) = {
        let row = results.statement(0).row(0).unwrap();
        (
            row.str(0).unwrap().to_owned(),
            row.str(1).unwrap().to_owned(),
        )
    };

    conn.push(&one, &[]).unwrap();
    conn.push(
        &insert,
        &[Param::Text(&username), Param::Text("fresh@example.invalid")],
    )
    .unwrap();
    conn.push(&one, &[]).unwrap();
    conn.push(&insert, &[Param::Text("fresh"), Param::Text(&email)])
        .unwrap();
    conn.flush_and_collect(&mut results).unwrap();
    assert_eq!(results.len(), 4);
    // The pipeline is one implicit transaction: the failure aborts it, but the first statement already answered.
    assert_eq!(results.statement(0).row(0).unwrap().i64(0).unwrap(), 1);
    let err = results.statement(1).error().expect("unique violation");
    assert!(err.is_unique_violation(), "{err}");
    assert!(results.statement(2).is_skipped() && results.statement(3).is_skipped());
    assert!(!conn.is_poisoned());

    // Same connection, next pipeline: works, and a good insert reports one affected row.
    conn.push(
        &insert,
        &[
            Param::Text("pg_agent_probe"),
            Param::Text("pg_agent_probe@example.invalid"),
        ],
    )
    .unwrap();
    conn.push(&one, &[]).unwrap();
    conn.flush_and_collect(&mut results).unwrap();
    assert!(results.statement(0).is_ok() && results.statement(1).is_ok());
    assert_eq!(results.statement(0).rows_affected(), 1);
    conn.query_simple("delete from users where username = 'pg_agent_probe'")
        .unwrap();
}

#[test]
#[ignore]
fn server_error_in_prepare_and_simple_query_keeps_the_connection() {
    let mut conn = connect();
    match conn.prepare("bad", "select from nowhere_table", &[]) {
        Err(PgError::Server(e)) => assert_eq!(e.sqlstate_str(), "42P01"),
        other => panic!("{:?}", other.err()),
    }
    assert!(matches!(
        conn.query_simple("select 1/0"),
        Err(PgError::Server(_))
    ));
    conn.query_simple("select 1").unwrap();
    assert!(!conn.is_poisoned());
}

#[test]
#[ignore]
fn io_failure_poisons_the_connection() {
    let mut conn = connect();
    let one = conn.prepare("one", "select 1", &[]).unwrap();
    assert!(
        conn.query_simple("select pg_terminate_backend(pg_backend_pid())")
            .is_err()
    );
    assert!(conn.is_poisoned());
    assert!(matches!(conn.push(&one, &[]), Err(PgError::Poisoned)));
    assert!(matches!(
        conn.query_simple("select 1"),
        Err(PgError::Poisoned)
    ));
    assert!(matches!(
        conn.flush_and_collect(&mut Results::new()),
        Err(PgError::Poisoned)
    ));
}

#[test]
#[ignore]
fn two_megabyte_row() {
    let mut conn = connect();
    let big = conn
        .prepare("big", "select repeat('é', $1::int4), 42::int8", &[INT4])
        .unwrap();
    let mut results = Results::new();
    const CHARS: i32 = 1_000_000; // 2 bytes each
    run_one(&mut conn, &big, &[Param::Int4(CHARS)], &mut results);
    let row = results.statement(0).row(0).unwrap();
    let text = row.str(0).unwrap();
    assert_eq!(text.len(), 2_000_000);
    assert!(text.chars().all(|c| c == 'é'));
    assert_eq!(row.i64(1).unwrap(), 42);
    // The connection keeps working after the buffer had to grow.
    run_one(&mut conn, &big, &[Param::Int4(3)], &mut results);
    assert_eq!(results.statement(0).row(0).unwrap().str(0).unwrap(), "ééé");
}

#[test]
#[ignore]
fn ten_thousand_small_rows() {
    let mut conn = connect();
    let rows = conn
        .prepare("rows", "select g::int8, 'row ' || g, g % 2 = 0, case when g % 3 = 0 then null else g::int4 end from generate_series(1, $1::int4) g", &[INT4])
        .unwrap();
    let mut results = Results::new();
    run_one(&mut conn, &rows, &[Param::Int4(10_000)], &mut results);
    let st = results.statement(0);
    assert_eq!(st.row_count(), 10_000);
    let mut sum = 0;
    for (i, row) in st.rows().enumerate() {
        let g = i as i64 + 1;
        assert_eq!(row.i64(0).unwrap(), g);
        assert_eq!(row.str(1).unwrap(), format!("row {g}"));
        assert_eq!(row.bool(2).unwrap(), g % 2 == 0);
        assert_eq!(row.is_null(3), g % 3 == 0);
        sum += g;
    }
    assert_eq!(sum, 50_005_000);
}

/// A pipeline whose request (20 MB) and reply (80 MB) both exceed the socket buffers: a plain blocking write would
/// deadlock against the server, which is blocked writing replies we are not reading.
#[test]
#[ignore]
fn large_pipeline_does_not_deadlock() {
    let mut conn = connect();
    let echo = conn
        .prepare(
            "echo",
            "select repeat('x', 4000), length($1::text)::int8",
            &[TEXT],
        )
        .unwrap();
    let payload = "y".repeat(1000);
    const COUNT: usize = 20_000;
    for _ in 0..COUNT {
        conn.push(&echo, &[Param::Text(&payload)]).unwrap();
    }
    let mut results = Results::new();
    conn.flush_and_collect(&mut results).unwrap();
    assert_eq!(results.len(), COUNT);
    for st in results.iter() {
        let row = st.row(0).unwrap();
        assert_eq!(
            (row.str(0).unwrap().len(), row.i64(1).unwrap()),
            (4000, 1000)
        );
    }
}

/// Prints numbers; asserts only that things ran. `cargo test --release --lib pg:: -- --ignored --nocapture bench`.
#[test]
#[ignore]
fn bench_round_trips() {
    let mut conn = connect();
    let one = conn.prepare("one", "select 1", &[]).unwrap();
    let mut results = Results::new();
    for (label, per_pipeline) in [("1 statement", 1usize), ("100 statements", 100)] {
        let started = Instant::now();
        let mut pipelines = 0u64;
        while started.elapsed() < Duration::from_secs(2) {
            for _ in 0..per_pipeline {
                conn.push(&one, &[]).unwrap();
            }
            conn.flush_and_collect(&mut results).unwrap();
            pipelines += 1;
        }
        let secs = started.elapsed().as_secs_f64();
        println!(
            "bench: pipeline of {label}: {:.0} round trips/s, {:.0} statements/s",
            pipelines as f64 / secs,
            (pipelines * per_pipeline as u64) as f64 / secs
        );
    }
}

/// CPU spent in this module per row: a synthetic DataRow stream (no socket) parsed by `Results`, and the typed
/// accessors over the stored rows. `Instant` around the loops only.
#[test]
#[ignore]
fn bench_decode_cpu_per_row() {
    const ROWS: usize = 10_000;
    let mut messages = Vec::with_capacity(ROWS);
    for g in 1..=ROWS as i64 {
        let text = format!("row {g}");
        let mut payload = 4u16.to_be_bytes().to_vec();
        payload.extend_from_slice(&8_i32.to_be_bytes());
        payload.extend_from_slice(&g.to_be_bytes());
        payload.extend_from_slice(&(text.len() as i32).to_be_bytes());
        payload.extend_from_slice(text.as_bytes());
        payload.extend_from_slice(&1_i32.to_be_bytes());
        payload.push(u8::from(g % 2 == 0));
        payload.extend_from_slice(&(-1_i32).to_be_bytes());
        messages.push(payload);
    }
    let mut results = Results::new();
    let mut parse_best = Duration::MAX;
    let mut read_best = Duration::MAX;
    for _ in 0..200 {
        results.begin(1);
        let started = Instant::now();
        for payload in &messages {
            results.on_message(b'D', payload).unwrap();
        }
        parse_best = parse_best.min(started.elapsed());
        results.on_message(b'C', b"SELECT 10000\0").unwrap();
        results.on_message(b'Z', b"I").unwrap();

        let started = Instant::now();
        let mut checksum = 0i64;
        for row in results.statement(0).rows() {
            checksum += row.i64(0).unwrap()
                + row.str(1).unwrap().len() as i64
                + i64::from(row.bool(2).unwrap())
                + i64::from(row.is_null(3));
        }
        read_best = read_best.min(started.elapsed());
        assert!(checksum > 0);
    }
    println!(
        "bench: DataRow parse {:.3} us/row, typed read of 4 columns {:.3} us/row (best of 200 runs over {ROWS} rows)",
        parse_best.as_secs_f64() * 1e6 / ROWS as f64,
        read_best.as_secs_f64() * 1e6 / ROWS as f64
    );
}

/// The same 10,000-row statement end to end over the socket, for context: includes the server's time.
#[test]
#[ignore]
fn bench_end_to_end_10k_rows() {
    let mut conn = connect();
    let rows = conn
        .prepare("rows", "select g::int8, 'row ' || g, g % 2 = 0, null::text from generate_series(1, $1::int4) g", &[INT4])
        .unwrap();
    let mut results = Results::new();
    let mut best = Duration::MAX;
    for _ in 0..50 {
        conn.push(&rows, &[Param::Int4(10_000)]).unwrap();
        let started = Instant::now();
        conn.flush_and_collect(&mut results).unwrap();
        best = best.min(started.elapsed());
    }
    println!(
        "bench: flush_and_collect of 10000 rows (wall, includes server): {:.3} us/row",
        best.as_secs_f64() * 1e6 / 10_000.0
    );
}
