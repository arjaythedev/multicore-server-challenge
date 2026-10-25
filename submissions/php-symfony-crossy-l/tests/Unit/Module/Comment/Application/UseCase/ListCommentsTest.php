<?php

declare(strict_types=1);

namespace App\Tests\Unit\Module\Comment\Application\UseCase;

use App\Module\Comment\Application\Mapper\CommentResultMapper;
use App\Module\Comment\Application\Mapper\CommentsResultMapper;
use App\Module\Comment\Application\UseCase\ListComments;
use App\Module\Comment\Domain\Repository\CommentRepositoryInterface;
use App\Module\Comment\Domain\View\CommentView;
use App\Module\Comment\Domain\View\CommentViewList;
use App\Shared\Application\Mapper\ProfileResultMapper;
use App\Shared\Domain\Model\Exception\NotFoundException;
use App\Shared\Domain\Model\Moment;
use App\Shared\Domain\View\ProfileView;
use PHPUnit\Framework\TestCase;

final class ListCommentsTest extends TestCase
{
    private static function mapper(): CommentsResultMapper
    {
        return new CommentsResultMapper(new CommentResultMapper(new ProfileResultMapper()));
    }

    public function testAnUnknownArticleIsNotFound(): void
    {
        $repository = $this->createMock(CommentRepositoryInterface::class);
        $repository->expects(self::once())->method('findNewestBySlug')->with('missing', 3)->willReturn(null);

        $this->expectException(NotFoundException::class);
        (new ListComments($repository, self::mapper()))('missing', 3);
    }

    public function testAnArticleWithoutCommentsIsAnEmptyList(): void
    {
        $repository = $this->createStub(CommentRepositoryInterface::class);
        $repository->method('findNewestBySlug')->willReturn(CommentViewList::fromArray([]));

        self::assertTrue((new ListComments($repository, self::mapper()))('quiet', 0)->comments->isEmpty());
    }

    public function testTheCommentsAreReadByTheSlugInOneCall(): void
    {
        $at = Moment::fromUtcText('2026-01-01 00:00:00+00');
        $repository = $this->createMock(CommentRepositoryInterface::class);
        $repository->expects(self::once())->method('findNewestBySlug')->with('busy', 3)
            ->willReturn(CommentViewList::fromArray([new CommentView(9, 'body', $at, $at, new ProfileView('someone', null, null, true))]));
        $repository->expects(self::never())->method('findArticleIdBySlug');

        $comments = (new ListComments($repository, self::mapper()))('busy', 3)->comments;

        self::assertSame([9], $comments->map(static fn ($comment): int => $comment->id));
    }
}
