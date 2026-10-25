<?php

declare(strict_types=1);

namespace App\Tests\Support;

/**
 * The reference statements of SPEC.md, word for word. They define the right answer: any statement the
 * server runs in their place must return what these return, and the equivalence tests check that.
 */
final class ReferenceSql
{
    /** $1 = viewer. */
    public const string LIST_SELECT = <<<'SQL'
        SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
               ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                      WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
               (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
               EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
               u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
          FROM articles a
          JOIN users u ON u.id = a.author_id
        SQL;

    /** $1 = viewer. The list select with a.body after a.description. */
    public const string FULL_SELECT = <<<'SQL'
        SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
               ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                      WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
               (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
               EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
               u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
          FROM articles a
          JOIN users u ON u.id = a.author_id
        SQL;

    public const string ORDER_PAGE = ' ORDER BY a.id DESC LIMIT $2 OFFSET $3';

    /** Parameters: viewer, limit, offset. */
    public const string PAGE_ALL = self::LIST_SELECT . self::ORDER_PAGE;

    public const string COUNT_ALL = 'SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s';

    /** Parameters: viewer, limit, offset, tag. */
    public const string PAGE_BY_TAG = self::LIST_SELECT
        . ' WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4)'
        . ' ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC';

    /** Parameter: tag. */
    public const string COUNT_BY_TAG = 'SELECT count(*) FROM (SELECT 1 FROM article_tags at'
        . ' WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s';

    /** Parameters: viewer, limit, offset, username. */
    public const string PAGE_BY_AUTHOR = self::LIST_SELECT
        . ' WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4)' . self::ORDER_PAGE;

    /** Parameter: username. */
    public const string COUNT_BY_AUTHOR = 'SELECT count(*) FROM (SELECT 1 FROM articles a'
        . ' WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s';

    /** Parameters: viewer, limit, offset, username. */
    public const string PAGE_FAVORITED_BY = self::LIST_SELECT
        . ' WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4)'
        . ' ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC';

    /** Parameter: username. */
    public const string COUNT_FAVORITED_BY = 'SELECT count(*) FROM (SELECT 1 FROM favorites f'
        . ' WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s';

    /** Parameters: viewer, limit, offset. */
    public const string PAGE_FEED = self::LIST_SELECT
        . ' WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL'
        . ' (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x'
        . ' WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC';

    /** Parameter: viewer. */
    public const string COUNT_FEED = 'SELECT count(*) FROM (SELECT 1 FROM articles a'
        . ' WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s';

    /** Parameters: viewer, slug. */
    public const string ARTICLE_BY_SLUG = self::FULL_SELECT . ' WHERE a.slug = $2';

    /** Parameters: viewer, id. */
    public const string ARTICLE_BY_ID = self::FULL_SELECT . ' WHERE a.id = $2';

    /** Parameter: slug. */
    public const string ARTICLE_ID_BY_SLUG = 'SELECT id FROM articles WHERE slug = $1';

    /** Parameters: viewer, article id. */
    public const string COMMENTS_OF_ARTICLE = <<<'SQL'
        SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following
          FROM comments c JOIN users u ON u.id = c.author_id
         WHERE c.article_id = $2
         ORDER BY c.created_at DESC, c.id DESC
         LIMIT 100
        SQL;
}
