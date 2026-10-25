<?php

declare(strict_types=1);

namespace App\Tests\Unit\Module\Article\Application\UseCase;

use App\Module\Article\Application\Mapper\ArticlesResultMapper;
use App\Module\Article\Application\Mapper\ArticleSummaryResultMapper;
use App\Module\Article\Application\UseCase\GetFeed;
use App\Module\Article\Application\UseCase\ListArticles;
use App\Module\Article\Domain\Model\ArticleFilter;
use App\Module\Article\Domain\Repository\ArticlePageRepositoryInterface;
use App\Module\Article\Domain\View\ArticlePageView;
use App\Module\Article\Domain\View\ArticleSummaryView;
use App\Module\Article\Domain\View\ArticleSummaryViewList;
use App\Shared\Application\Mapper\ProfileResultMapper;
use App\Shared\Domain\Model\Moment;
use App\Shared\Domain\View\ProfileView;
use PHPUnit\Framework\TestCase;

final class ListArticlesTest extends TestCase
{
    public function testTheCountComesWithThePageNotFromASecondRead(): void
    {
        $filter = ArticleFilter::byTag('php');
        $repository = $this->createMock(ArticlePageRepositoryInterface::class);
        $repository->expects(self::once())->method('findPage')->with($filter, 7, 10, 20)
            ->willReturn(new ArticlePageView(ArticleSummaryViewList::fromArray([self::summary('first')]), 345));

        $result = (new ListArticles($repository, self::mapper()))($filter, 7, 10, 20);

        self::assertSame(345, $result->articlesCount);
        self::assertSame(['first'], $result->articles->map(static fn ($article): string => $article->slug));
    }

    public function testAnEmptyPageKeepsItsCount(): void
    {
        $repository = $this->createStub(ArticlePageRepositoryInterface::class);
        $repository->method('findPage')->willReturn(new ArticlePageView(ArticleSummaryViewList::fromArray([]), 1000));

        $result = (new ListArticles($repository, self::mapper()))(ArticleFilter::none(), 0, 10, 100000);

        self::assertTrue($result->articles->isEmpty());
        self::assertSame(1000, $result->articlesCount);
    }

    public function testTheFeedCountComesWithThePageToo(): void
    {
        $repository = $this->createMock(ArticlePageRepositoryInterface::class);
        $repository->expects(self::once())->method('findFeedPage')->with(7, 5, 0)
            ->willReturn(new ArticlePageView(ArticleSummaryViewList::fromArray([self::summary('mine')]), 12));

        $result = (new GetFeed($repository, self::mapper()))(7, 5, 0);

        self::assertSame(12, $result->articlesCount);
        self::assertSame(['mine'], $result->articles->map(static fn ($article): string => $article->slug));
    }

    private static function mapper(): ArticlesResultMapper
    {
        return new ArticlesResultMapper(new ArticleSummaryResultMapper(new ProfileResultMapper()));
    }

    private static function summary(string $slug): ArticleSummaryView
    {
        $at = Moment::fromUtcText('2026-01-01 00:00:00+00');

        return new ArticleSummaryView($slug, 'title', 'description', [], $at, $at, false, 0, new ProfileView('author', null, null, false));
    }
}
