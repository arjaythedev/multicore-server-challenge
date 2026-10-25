<?php

declare(strict_types=1);

namespace App\Tests\Unit\Module\Article\Infrastructure\Persistence\Pg\Mapper;

use App\Module\Article\Infrastructure\Persistence\Pg\Mapper\ArticleSummaryViewMapper;
use App\Shared\Infrastructure\Persistence\Pg\Mapper\ProfileViewMapper;
use PHPUnit\Framework\TestCase;

final class ArticleSummaryViewMapperTest extends TestCase
{
    public function testARowBecomesAnArticleWithoutItsBody(): void
    {
        $article = $this->mapper()->toView([
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
        self::assertSame('Ever wonder how?', $article->description);
        self::assertSame(['dragons', 'training'], $article->tagList);
        self::assertSame(12, $article->favoritesCount);
        self::assertSame('jake', $article->author->username);
    }

    public function testRowsBecomeAListInTheirOrder(): void
    {
        $first = [
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
        ];
        $second = ['slug' => 'second-8'] + $first;

        self::assertSame(['how-to-train-your-dragon-7', 'second-8'], $this->mapper()->toViewList([$first, $second])->map(static fn ($article): string => $article->slug));
    }

    public function testTheRowOfAnEmptyPageIsNoArticle(): void
    {
        $row = array_fill_keys(['id', 'slug', 'title', 'description', 'tag_list', 'created_at', 'updated_at', 'favorited', 'favorites_count', 'username', 'bio', 'image', 'following'], null) + ['total' => '1000'];

        self::assertTrue($this->mapper()->toViewList([$row])->isEmpty());
        self::assertTrue($this->mapper()->toViewList([])->isEmpty());
    }

    private function mapper(): ArticleSummaryViewMapper
    {
        return new ArticleSummaryViewMapper(new ProfileViewMapper());
    }
}
