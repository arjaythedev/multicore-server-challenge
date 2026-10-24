package conduit.app

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Structural checks of the catalog (the statements themselves were verified against Postgres: see the commit
 * message). These catch edits that break the batching contract.
 */
class SqlTest {
    private val unnest = "unnest(\$1::int4[], \$2::int8[], \$3::int4[], \$4::int8[], \$5::text[]) AS r(i, v, l, o, k)"
    private val param = Regex("\\$(\\d+)")

    @Test
    fun readsFollowTheBatchLayout() {
        val names = HashSet<String>()
        for (k in Sql.reads) {
            assertTrue(names.add(k.name), "duplicate kind ${k.name}")
            assertTrue(k.sql.startsWith("SELECT r.i, "), "${k.name}: first column must be r.i")
            assertTrue(k.sql.contains(unnest), "${k.name}: uniform 5-array unnest")
            // the arrays are referenced only by the unnest: everything else uses request columns
            assertEquals(5, param.findAll(k.sql).count(), "${k.name}: \$n outside the unnest")
            // probes, not EXISTS (inside a batch EXISTS became a hashed subplan over all of the viewer's rows)
            assertFalse(k.sql.contains("EXISTS (SELECT 1 FROM favorites"), k.name)
            assertFalse(k.sql.contains("EXISTS (SELECT 1 FROM follows"), k.name)
        }
        assertEquals(13, Sql.reads.size)
    }

    @Test
    fun uncorrelatedSubqueriesAreTiedToTheRequest() {
        // Without `r.i >= 0` these subqueries are InitPlans run once per statement and shared (rule 5).
        assertTrue(Sql.TAGS.sql.contains("WHERE r.i >= 0 ORDER BY t.name"))
        for (k in listOf(Sql.LIST_ALL, Sql.LIST_ALL_DEEP)) {
            assertTrue(k.sql.contains("FROM articles c WHERE r.i >= 0 ORDER BY c.id OFFSET 999"), k.name)
            assertTrue(k.sql.contains("(SELECT count(*) FROM articles c WHERE r.i >= 0)"), k.name)
        }
        // The count must stay a per-request subquery (pulled up it runs once per article row).
        for (k in listOf(Sql.LIST_ALL, Sql.LIST_ALL_DEEP, Sql.LIST_AUTHOR, Sql.LIST_TAG, Sql.LIST_FAVORITED, Sql.FEED)) {
            assertTrue(k.sql.startsWith("SELECT r.i, c.n, x.* FROM $unnest CROSS JOIN LATERAL (SELECT "), k.name)
            assertTrue(k.sql.contains(" AS n OFFSET 0) c LEFT JOIN LATERAL ("), k.name)
            assertTrue(k.sql.endsWith(") x ON true"), k.name)
        }
    }

    @Test
    fun tagNamesAreSortedInSql() {
        for (k in listOf(Sql.ARTICLE_BY_SLUG, Sql.ARTICLE_BY_ID, Sql.LIST_ALL, Sql.LIST_TAG, Sql.FEED)) {
            assertTrue(k.sql.contains("WHERE at.article_id = a.id ORDER BY 1)"), k.name)
        }
        assertTrue(Sql.ARTICLE_CREATE.sql.contains("ARRAY(SELECT g.name FROM g ORDER BY 1)"))
    }

    @Test
    fun writesDeclareEveryParameter() {
        val names = HashSet<String>()
        for (w in Sql.writes) {
            assertTrue(names.add(w.name), "duplicate write ${w.name}")
            val used = param.findAll(w.sql).map { it.groupValues[1].toInt() }.toSet()
            assertEquals((1..w.paramOids.size).toSet(), used, "${w.name}: parameters vs OIDs")
        }
        assertEquals(11, Sql.writes.size)
    }

    @Test
    fun appExposesTheCatalog() {
        assertEquals(Sql.reads, App.reads)
        assertEquals(Sql.writes, App.writes)
    }
}
