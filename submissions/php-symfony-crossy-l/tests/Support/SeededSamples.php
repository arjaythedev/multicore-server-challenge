<?php

declare(strict_types=1);

namespace App\Tests\Support;

use App\Shared\Infrastructure\Persistence\Pg\PgConnection;

/**
 * Picks, from the seeded database, the viewers, tags, usernames and articles that make an equivalence
 * test cover the interesting cases: the heaviest and the emptiest of each kind, a few spread through the
 * data, and some that do not exist. The picks are deterministic for a given seed.
 */
final class SeededSamples
{
    /** Pairs of limit and offset: a page, a later page, one beyond the end, and odd sizes. */
    public const array WINDOWS = [[10, 0], [10, 10], [10, 40], [1, 0], [5, 5], [20, 0], [100, 0], [3, 7], [10, 100000], [10, 10000000]];

    public function __construct(
        private readonly PgConnection $connection,
    ) {
    }

    /**
     * The anonymous viewer, the users who follow and favorite the most, one who does neither, and a few
     * spread through the users.
     *
     * @return list<int>
     */
    public function viewerIds(): array
    {
        return array_values(array_unique([
            0,
            ...$this->ints('SELECT follower_id FROM follows GROUP BY follower_id ORDER BY count(*) DESC, follower_id LIMIT 2'),
            ...$this->ints('SELECT user_id FROM favorites GROUP BY user_id ORDER BY count(*) DESC, user_id LIMIT 2'),
            ...$this->ints(<<<'SQL'
                SELECT id FROM users u
                 WHERE NOT EXISTS (SELECT 1 FROM follows f WHERE f.follower_id = u.id)
                   AND NOT EXISTS (SELECT 1 FROM favorites v WHERE v.user_id = u.id)
                 ORDER BY id LIMIT 1
                SQL),
            ...$this->ints('SELECT id FROM users ORDER BY md5(id::text) LIMIT 3'),
        ]));
    }

    /**
     * The most and the least used tag, one in between, and one that does not exist.
     *
     * @return list<string>
     */
    public function tags(): array
    {
        return [
            ...$this->strings('SELECT t.name FROM tags t JOIN article_tags x ON x.tag_id = t.id GROUP BY t.name ORDER BY count(*) DESC, t.name LIMIT 1'),
            ...$this->strings('SELECT t.name FROM tags t JOIN article_tags x ON x.tag_id = t.id GROUP BY t.name ORDER BY count(*), t.name LIMIT 1'),
            ...$this->strings('SELECT name FROM tags ORDER BY md5(name) LIMIT 1'),
            'no-such-tag',
        ];
    }

    /**
     * The author of the most articles, one with a single article, a user who wrote none, and a name that
     * belongs to nobody.
     *
     * @return list<string>
     */
    public function authors(): array
    {
        return [
            ...$this->strings('SELECT u.username FROM users u JOIN articles a ON a.author_id = u.id GROUP BY u.username ORDER BY count(*) DESC, u.username LIMIT 1'),
            ...$this->strings('SELECT u.username FROM users u JOIN articles a ON a.author_id = u.id GROUP BY u.username HAVING count(*) = 1 ORDER BY u.username LIMIT 1'),
            ...$this->strings('SELECT username FROM users u WHERE NOT EXISTS (SELECT 1 FROM articles a WHERE a.author_id = u.id) ORDER BY id LIMIT 1'),
            'no-such-user',
        ];
    }

    /**
     * The user with the most favorites, one with none, and a name that belongs to nobody.
     *
     * @return list<string>
     */
    public function favoriters(): array
    {
        return [
            ...$this->strings('SELECT u.username FROM users u JOIN favorites f ON f.user_id = u.id GROUP BY u.username ORDER BY count(*) DESC, u.username LIMIT 1'),
            ...$this->strings('SELECT username FROM users u WHERE NOT EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = u.id) ORDER BY id LIMIT 1'),
            'no-such-user',
        ];
    }

    /**
     * The newest, the oldest and a middle article, the most favorited, one with no tags if there is one,
     * and a slug that belongs to nobody.
     *
     * @return list<string>
     */
    public function articleSlugs(): array
    {
        return [
            ...$this->strings('SELECT slug FROM articles ORDER BY id DESC LIMIT 2'),
            ...$this->strings('SELECT slug FROM articles ORDER BY id LIMIT 1'),
            ...$this->strings('SELECT slug FROM articles ORDER BY md5(id::text) LIMIT 3'),
            ...$this->strings('SELECT a.slug FROM articles a JOIN favorites f ON f.article_id = a.id GROUP BY a.slug ORDER BY count(*) DESC, a.slug LIMIT 1'),
            ...$this->strings('SELECT slug FROM articles a WHERE NOT EXISTS (SELECT 1 FROM article_tags x WHERE x.article_id = a.id) ORDER BY id LIMIT 1'),
            'no-such-article',
        ];
    }

    /**
     * The article with the most comments, one with exactly one, one with none, and a slug that belongs
     * to nobody.
     *
     * @return list<string>
     */
    public function commentedSlugs(): array
    {
        return [
            ...$this->strings('SELECT a.slug FROM articles a JOIN comments c ON c.article_id = a.id GROUP BY a.slug ORDER BY count(*) DESC, a.slug LIMIT 1'),
            ...$this->strings('SELECT a.slug FROM articles a JOIN comments c ON c.article_id = a.id GROUP BY a.slug HAVING count(*) = 1 ORDER BY a.slug LIMIT 1'),
            ...$this->strings('SELECT slug FROM articles a WHERE NOT EXISTS (SELECT 1 FROM comments c WHERE c.article_id = a.id) ORDER BY id LIMIT 1'),
            ...$this->strings('SELECT a.slug FROM articles a JOIN comments c ON c.article_id = a.id GROUP BY a.slug ORDER BY md5(a.slug) LIMIT 2'),
            'no-such-article',
        ];
    }

    /**
     * @return list<int>
     */
    private function ints(string $sql): array
    {
        return array_map(intval(...), pg_fetch_all_columns($this->connection->read($sql, []), 0));
    }

    /**
     * @return list<string>
     */
    private function strings(string $sql): array
    {
        return array_map(strval(...), pg_fetch_all_columns($this->connection->read($sql, []), 0));
    }
}
