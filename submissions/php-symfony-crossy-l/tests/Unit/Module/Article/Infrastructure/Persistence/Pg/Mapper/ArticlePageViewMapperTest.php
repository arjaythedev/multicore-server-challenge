<?php

declare(strict_types=1);

namespace App\Tests\Unit\Module\Article\Infrastructure\Persistence\Pg\Mapper;

use App\Module\Article\Infrastructure\Persistence\Pg\Mapper\ArticlePageViewMapper;
use App\Module\Article\Infrastructure\Persistence\Pg\Mapper\ArticleSummaryViewMapper;
use App\Shared\Infrastructure\Persistence\Pg\Mapper\ProfileViewMapper;
use PHPUnit\Framework\TestCase;

final class ArticlePageViewMapperTest extends TestCase
{
    public function testThePageCarriesTheSizeOfTheWholeList(): void
    {
        $row = ['total' => '345'] + [
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

        $page = $this->mapper()->toView([$row, $row]);

        self::assertSame(345, $page->count);
        self::assertCount(2, $page->articles->map(static fn ($article): string => $article->slug));
    }

    public function testAPageWithoutArticlesKeepsItsCount(): void
    {
        $row = array_fill_keys(['id', 'slug', 'title', 'description', 'tag_list', 'created_at', 'updated_at', 'favorited', 'favorites_count', 'username', 'bio', 'image', 'following'], null) + ['total' => '1000'];

        $page = $this->mapper()->toView([$row]);

        self::assertSame(1000, $page->count);
        self::assertTrue($page->articles->isEmpty());
    }

    private function mapper(): ArticlePageViewMapper
    {
        return new ArticlePageViewMapper(new ArticleSummaryViewMapper(new ProfileViewMapper()));
    }
}
