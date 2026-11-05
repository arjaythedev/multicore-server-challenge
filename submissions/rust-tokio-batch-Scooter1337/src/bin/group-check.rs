use tokio_postgres::NoTls;
#[tokio::main]
async fn main() {
    let (c, connection) = tokio_postgres::connect(&std::env::var("DATABASE_URL").unwrap(), NoTls)
        .await
        .unwrap();
    tokio::spawn(async move {
        connection.await.unwrap();
    });
    let q = c.prepare("SELECT $1::bigint, $2::text").await.unwrap();
    let none = c.prepare("SELECT 1 WHERE false").await.unwrap();
    let bad = c.prepare("SELECT 10 / $1::int").await.unwrap();
    for n in [1, 2, 8, 32] {
        let data: Vec<_> = (0..n).map(|i| (i as i64, format!("row {i} é"))).collect();
        let requests: Vec<_> = data
            .iter()
            .map(|(i, s)| (&q, vec![i as &(dyn tokio_postgres::types::ToSql + Sync), s]))
            .collect();
        let rows = c.query_group(&requests).await.unwrap();
        assert_eq!(rows.len(), n);
        for (i, r) in rows.iter().enumerate() {
            assert_eq!(r.len(), 1);
            assert_eq!(r[0].get::<_, i64>(0), i as i64);
            assert_eq!(r[0].get::<_, &str>(1), data[i].1);
        }
    }
    let rows = c
        .query_group(&[(&none, vec![]), (&q, vec![&5i64, &"last"])])
        .await
        .unwrap();
    assert!(rows[0].is_empty());
    assert_eq!(rows[1][0].get::<_, i64>(0), 5);
    let requests = vec![
        (
            &q,
            vec![
                &1i64 as &(dyn tokio_postgres::types::ToSql + Sync),
                &"first",
            ],
        ),
        (&bad, vec![&0i32]),
        (&q, vec![&2i64, &"skipped"]),
    ];
    let e = c.query_group(&requests).await.unwrap_err();
    assert_eq!(e.code().unwrap().code(), "22012");
    assert_eq!(
        c.query_one("SELECT 123::bigint", &[])
            .await
            .unwrap()
            .get::<_, i64>(0),
        123
    );
    assert_eq!(
        c.query_group(&[(&q, vec![&3i64, &"recovered"])])
            .await
            .unwrap()[0][0]
            .get::<_, i64>(0),
        3
    );
    let frame = tokio_postgres::Client::encode_group_query(&q, &[&44i64, &"packed"]).unwrap();
    let empty = tokio_postgres::Client::encode_group_query(&none, &[]).unwrap();
    let rows = c
        .query_group_encoded(&[(&q, frame.clone()), (&none, empty)])
        .await
        .unwrap();
    assert_eq!(rows[0][0].get::<_, i64>(0), 44);
    assert!(rows[1].is_empty());
    let badframe = tokio_postgres::Client::encode_group_query(&bad, &[&0i32]).unwrap();
    assert!(
        c.query_group_encoded(&[(&q, frame.clone()), (&bad, badframe), (&q, frame)])
            .await
            .is_err()
    );
    assert_eq!(
        c.query_one("SELECT 456::bigint", &[])
            .await
            .unwrap()
            .get::<_, i64>(0),
        456
    );
    let (writer, driver) = tokio_postgres::connect(&std::env::var("DATABASE_URL").unwrap(), NoTls)
        .await
        .unwrap();
    tokio::spawn(async move {
        driver.await.unwrap();
    });
    let old: Option<String> = writer
        .query_one("SELECT bio FROM users WHERE id=1", &[])
        .await
        .unwrap()
        .get(0);
    let a = c
        .prepare("SELECT pg_sleep(0.15), bio FROM users WHERE id=1")
        .await
        .unwrap();
    let b = c.prepare("SELECT bio FROM users WHERE id=1").await.unwrap();
    let requests = [(&a, Vec::new()), (&b, Vec::new())];
    let (results, _) = tokio::join!(c.query_group(&requests), async {
        tokio::time::sleep(std::time::Duration::from_millis(40)).await;
        writer
            .execute(
                "UPDATE users SET bio='group snapshot check' WHERE id=1",
                &[],
            )
            .await
            .unwrap();
    });
    let rows = results.unwrap();
    assert_eq!(rows[0][0].get::<_, Option<String>>(1), old);
    assert_eq!(rows[1][0].get::<_, &str>(0), "group snapshot check");
    writer
        .execute("UPDATE users SET bio=$1 WHERE id=1", &[&old])
        .await
        .unwrap();
    println!("PASS distinct READ COMMITTED statement snapshots");
    println!("PASS packed frames including SQL error drain");
    println!("PASS group sizes 1/2/8/32, empty result, SQL error drain and connection reuse");
}
