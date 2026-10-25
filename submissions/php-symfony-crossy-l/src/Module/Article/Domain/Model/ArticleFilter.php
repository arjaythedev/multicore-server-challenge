<?php

declare(strict_types=1);

namespace App\Module\Article\Domain\Model;

/**
 * Which articles a list holds: all of them, those with a tag, those by an author, or those a user
 * favorited. The value is the tag name or the username, and empty for all of them.
 */
readonly class ArticleFilter
{
    private function __construct(
        public ArticleFilterKind $kind,
        public string $value,
    ) {
    }

    public static function none(): self
    {
        return new self(ArticleFilterKind::None, '');
    }

    public static function byTag(string $tag): self
    {
        return new self(ArticleFilterKind::Tag, $tag);
    }

    public static function byAuthor(string $username): self
    {
        return new self(ArticleFilterKind::Author, $username);
    }

    public static function favoritedBy(string $username): self
    {
        return new self(ArticleFilterKind::FavoritedBy, $username);
    }
}
