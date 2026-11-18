-- Which of a page's articles (p.ids, by p.authors) request r's reader has favorited, and which authors they
-- follow: one index scan each over the reader's own rows, instead of a probe per article.
SELECT ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = r.viewer AND f.article_id = ANY (p.ids)) AS favorited,
       ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.viewer AND fo.followee_id = ANY (p.authors)) AS following
