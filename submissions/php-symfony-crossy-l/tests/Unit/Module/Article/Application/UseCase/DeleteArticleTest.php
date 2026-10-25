<?php

declare(strict_types=1);

namespace App\Tests\Unit\Module\Article\Application\UseCase;

use App\Module\Article\Application\Rule\ArticleAuthorRule;
use App\Module\Article\Application\UseCase\DeleteArticle;
use App\Module\Article\Domain\Model\ArticleAuthorship;
use App\Module\Article\Domain\Repository\ArticleRepositoryInterface;
use App\Shared\Domain\Model\Exception\ForbiddenException;
use App\Shared\Domain\Model\Exception\NotFoundException;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Throwable;

final class DeleteArticleTest extends TestCase
{
    /** @return iterable<string, array{?ArticleAuthorship, class-string<Throwable>}> */
    public static function deniedDeletes(): iterable
    {
        yield 'missing' => [null, NotFoundException::class];
        yield 'another author' => [new ArticleAuthorship(10, 2), ForbiddenException::class];
    }

    #[DataProvider('deniedDeletes')]
    public function testNoWriteHappensWhenTheArticleIsMissingOrOwnedByAnotherUser(?ArticleAuthorship $authorship, string $exception): void
    {
        $repository = $this->createMock(ArticleRepositoryInterface::class);
        $repository->method('findAuthorshipBySlug')->willReturn($authorship);
        $repository->expects(self::never())->method('delete');

        $this->expectException($exception);
        new DeleteArticle($repository, new ArticleAuthorRule())(1, 'slug');
    }

    public function testTheAuthorDeletesTheIdReadForTheSlug(): void
    {
        $repository = $this->createMock(ArticleRepositoryInterface::class);
        $repository->expects(self::once())->method('findAuthorshipBySlug')->with('slug')->willReturn(new ArticleAuthorship(10, 1));
        $repository->expects(self::once())->method('delete')->with(10);

        new DeleteArticle($repository, new ArticleAuthorRule())(1, 'slug');
    }
}
