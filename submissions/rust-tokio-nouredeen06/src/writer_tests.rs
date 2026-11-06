//! Explicit opt-in integration check. Uses a disposable PostgreSQL database;
//! never starts a database or loads the challenge seed itself.
use super::*;
use tokio_postgres::NoTls;

#[tokio::test]
#[ignore = "requires WRITER_TEST_DATABASE_URL pointing to a disposable database"]
async fn packed_writes_preserve_commit_rollback_and_parameters() {
    let url = std::env::var("WRITER_TEST_DATABASE_URL").expect("disposable test database URL");
    let (raw, driver) = tokio_postgres::connect(&url, NoTls).await.unwrap();
    tokio::spawn(async move { driver.await.unwrap() });
    let (observer, driver) = tokio_postgres::connect(&url, NoTls).await.unwrap();
    tokio::spawn(async move { driver.await.unwrap() });
    raw.batch_execute(
        "CREATE TABLE writer_fixture (
         id bigint PRIMARY KEY, body text, tags text[], payload bytea,
         parent bigint REFERENCES writer_fixture(id) DEFERRABLE INITIALLY DEFERRED)",
    )
    .await
    .unwrap();
    let insert = raw
        .prepare(
            "INSERT INTO writer_fixture VALUES ($1,$2,$3,$4,$5) RETURNING id,body,tags,payload",
        )
        .await
        .unwrap();
    let empty = raw
        .prepare("DELETE FROM writer_fixture WHERE id=$1 RETURNING id")
        .await
        .unwrap();
    let client = Client::new(raw, true, Vec::new());
    let tags = vec!["rust", "雪"];
    let payload = vec![0u8, 255, 1];
    let body: Option<&str> = None;
    let parent: Option<i64> = None;
    let row = client
        .query_one(&insert, &[&1i64, &body, &tags, &payload, &parent])
        .await
        .unwrap();
    assert_eq!(row.get::<_, i64>(0), 1);
    assert_eq!(row.get::<_, Option<String>>(1), None);
    // A separate connection must see the write as soon as its reply resolves.
    assert_eq!(count(&observer).await, 1);

    let results = futures_util::future::join_all((2i64..=17).map(|id| {
        let client = &client;
        let insert = &insert;
        let tags = &tags;
        let payload = &payload;
        async move {
            let body = (id % 4 != 0).then(|| format!("body-{id}-é\n\\"));
            let parent = Some(1i64);
            let row = client
                .query_one(insert, &[&id, &body, tags, payload, &parent])
                .await
                .unwrap();
            assert_eq!(row.get::<_, i64>(0), id);
            assert_eq!(row.get::<_, Option<String>>(1), body);
            assert_eq!(row.get::<_, Vec<String>>(2), *tags);
            assert_eq!(row.get::<_, Vec<u8>>(3), *payload);
        }
    }))
    .await;
    assert_eq!(results.len(), 16);
    assert_eq!(count(&observer).await, 17);

    // A failed middle statement skips subsequent packed commands until Sync.
    // Roll back first, then individually retry every job, including skipped ones.
    let insert_one = |id: i64, parent: Option<i64>| {
        let client = &client;
        let insert = &insert;
        let tags = &tags;
        let payload = &payload;
        async move {
            client
                .query(insert, &[&id, &body, tags, payload, &parent])
                .await
        }
    };
    let results =
        futures_util::future::join_all([18i64, 1, 19].into_iter().map(|id| insert_one(id, None)))
            .await;
    assert_eq!(results[0].as_ref().unwrap()[0].get::<_, i64>(0), 18);
    assert_eq!(
        results[1].as_ref().unwrap_err().code(),
        Some(&SqlState::UNIQUE_VIOLATION)
    );
    assert_eq!(results[2].as_ref().unwrap()[0].get::<_, i64>(0), 19);
    assert_eq!(count(&observer).await, 19);

    // A constraint deferred to COMMIT must not expose tentative success rows.
    // Even the valid neighbor rolls back, and an uncertain commit is not retried.
    let results = futures_util::future::join_all(
        [(20i64, Some(9999i64)), (21, None)]
            .into_iter()
            .map(|(id, parent)| insert_one(id, parent)),
    )
    .await;
    assert!(
        results
            .iter()
            .all(|r| r.as_ref().unwrap_err().code() == Some(&SqlState::FOREIGN_KEY_VIOLATION))
    );
    assert_eq!(count(&observer).await, 19);

    // Empty results and a succeeding write retain their order on the reused connection.
    let empty_params = [&9999i64 as &(dyn ToSql + Sync)];
    let (empty_result, rows) =
        tokio::join!(client.query(&empty, &empty_params), insert_one(22, None));
    assert!(empty_result.unwrap().is_empty());
    assert_eq!(rows.unwrap()[0].get::<_, i64>(0), 22);
    assert_eq!(count(&observer).await, 20);
    observer
        .batch_execute("DROP TABLE writer_fixture")
        .await
        .unwrap();
}

async fn count(client: &tokio_postgres::Client) -> i64 {
    client
        .query_one("SELECT count(*) FROM writer_fixture", &[])
        .await
        .unwrap()
        .get(0)
}
