package main

import (
	"strconv"
	"strings"
)

// All metadata is scoped to this SQL execution. Distinct page IDs, author IDs,
// and tag IDs avoid repeating the same heap and tag-name probes per recipient.
func metadataCTEs(ids string, full bool) string {
	body := ""
	if full {
		body = ",a.body"
	}
	return `article_rows AS MATERIALIZED (
 SELECT a.id,a.slug,a.title,a.description` + body + `,a.created_at,a.updated_at,a.author_id
 FROM ` + ids + ` i JOIN articles a ON a.id=i.id),
 author_profiles AS MATERIALIZED (
 SELECT u.id,u.username,u.bio,u.image FROM (SELECT DISTINCT author_id FROM article_rows) a JOIN users u ON u.id=a.author_id),
 tag_links AS MATERIALIZED (SELECT at.article_id,at.tag_id FROM article_rows a JOIN article_tags at ON at.article_id=a.id),
 tag_names AS MATERIALIZED (SELECT t.id,t.name FROM (SELECT DISTINCT tag_id FROM tag_links) k JOIN tags t ON t.id=k.tag_id),
 article_tag_lists AS MATERIALIZED (SELECT l.article_id,array_agg(t.name ORDER BY t.name) AS tags
 FROM tag_links l JOIN tag_names t ON t.id=l.tag_id GROUP BY l.article_id),
 enriched AS MATERIALIZED (
 SELECT a.*,COALESCE(t.tags,'{}'::text[]) AS tags,
 (SELECT count(*) FROM favorites f WHERE f.article_id=a.id) AS fc,u.username,u.bio,u.image
 FROM article_rows a JOIN author_profiles u ON u.id=a.author_id LEFT JOIN article_tag_lists t ON t.article_id=a.id)`
}

func optimizedListStatement(page, count string, feed bool) string {
	_, originalIDs, ok := strings.Cut(page, " WHERE a.id IN (")
	if !ok || !strings.HasSuffix(originalIDs, ") ORDER BY a.id DESC") {
		panic("list selector missing")
	}
	originalIDs = strings.TrimSuffix(originalIDs, ") ORDER BY a.id DESC")
	ids := originalIDs
	if feed && envOr("FEED_RECENT_SCAN", "0") != "0" {
		ids = hybridFeedIDs(ids)
	}
	// Keep scalar enrichment independently selectable from the feed strategy.
	if envOr("SQL_METADATA_BATCH", "0") == "0" {
		page = favoriteSQL(strings.Replace(page, originalIDs, ids, 1))
		return `WITH total AS (` + count + `) SELECT total.count,page.* FROM total LEFT JOIN LATERAL (` + page + `) page ON true ORDER BY page.id DESC`
	}
	following := `EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following`
	if feed {
		following = "true AS following"
	}
	return `WITH total AS (` + count + `), page_ids(id) AS MATERIALIZED (` + ids + `), ` + metadataCTEs("page_ids", false) + `
 SELECT total.count,a.id,a.slug,a.title,a.description,a.created_at,a.updated_at,a.tags,a.fc,
 EXISTS(SELECT 1 FROM favorites f WHERE f.article_id=a.id AND f.user_id=$1),a.username,a.bio,a.image,` + following + `
 FROM total LEFT JOIN enriched a ON true ORDER BY a.id DESC`
}

// A recent prefix is sufficient only when it contains limit+offset matches.
// Otherwise the complete reference selector runs in the same statement snapshot.
// The prefix and gate use live rows, with no assumptions about seed IDs or authors.
func hybridFeedIDs(fallback string) string {
	window, err := strconv.Atoi(envOr("FEED_SCAN_WINDOW", "512"))
	if err != nil || window < 1 || window > 16384 {
		panic("invalid FEED_SCAN_WINDOW")
	}
	const need = `LEAST($2::bigint::numeric+$3::bigint::numeric,9223372036854775807)::bigint`
	return `WITH followed AS MATERIALIZED (SELECT followee_id FROM follows WHERE follower_id=$1),
 recent AS MATERIALIZED (SELECT id,author_id FROM articles WHERE (` + need + `)<=` + strconv.Itoa(window) + ` AND (SELECT count(*) FROM followed)>=16 ORDER BY id DESC LIMIT ` + strconv.Itoa(window) + `),
 matches AS MATERIALIZED (SELECT r.id FROM recent r WHERE r.author_id IN (SELECT followee_id FROM followed) ORDER BY r.id DESC LIMIT (` + need + `)),
 enough AS MATERIALIZED (SELECT count(*)>=(` + need + `) AS yes FROM matches)
 SELECT id FROM (
 (SELECT id FROM matches WHERE (SELECT yes FROM enough) ORDER BY id DESC LIMIT $2 OFFSET $3)
 UNION ALL
 (SELECT id FROM (` + fallback + `) original WHERE NOT (SELECT yes FROM enough))
 ) chosen ORDER BY id DESC`
}

func favoriteSQL(sql string) string {
	if envOr("PG_FAVORITE_MODE", "combined") != "separate" {
		return sql
	}
	return strings.ReplaceAll(sql, `count(*) AS n, COALESCE(bool_or(f.user_id=$1),false) AS favorited`,
		`count(*) AS n, EXISTS(SELECT 1 FROM favorites member WHERE member.article_id=a.id AND member.user_id=$1) AS favorited`)
}
