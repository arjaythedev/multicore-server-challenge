<?php

declare(strict_types=1);

namespace App\Tests\Unit\Module\Article\Infrastructure\Persistence\Pg\Mapper;

use App\Module\Article\Infrastructure\Persistence\Pg\Mapper\ArticleViewMapper;
use App\Shared\Infrastructure\Persistence\Pg\Mapper\ProfileViewMapper;
use PHPUnit\Framework\TestCase;

final class ArticleViewMapperTest extends TestCase
{
    public function testARowBecomesAnArticleWithItsAuthor(): void
    {
        $article = (new ArticleViewMapper(new ProfileViewMapper()))->toView([
            'id' => '7',
            'slug' => 'how-to-train-your-dragon-7',
            'title' => 'How to train your dragon',
            'description' => 'Ever wonder how?',
            'body' => 'It takes a Jacobian',
            'tag_list' => '{dragons,training}',
            'created_at' => '2026-01-02 03:04:05.678123+00',
            'updated_at' => '2026-02-03 04:05:06.1+00',
            'favorited' => 't',
            'favorites_count' => '12',
            'username' => 'jake',
            'bio' => null,
            'image' => 'https://example.test/jake.png',
            'following' => 'f',
        ]);

        self::assertSame('how-to-train-your-dragon-7', $article->slug);
        self::assertSame('It takes a Jacobian', $article->body);
        self::assertSame(['dragons', 'training'], $article->tagList);
        self::assertSame('2026-01-02T03:04:05.678Z', $article->createdAt->toIso8601());
        self::assertSame('2026-02-03T04:05:06.100Z', $article->updatedAt->toIso8601());
        self::assertTrue($article->favorited);
        self::assertSame(12, $article->favoritesCount);
        self::assertSame('jake', $article->author->username);
        self::assertNull($article->author->bio);
        self::assertFalse($article->author->following);
    }
}
