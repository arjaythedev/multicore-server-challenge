<?php

declare(strict_types=1);

namespace App\Tests\Unit\Module\Comment\Infrastructure\Persistence\Pg\Mapper;

use App\Module\Comment\Infrastructure\Persistence\Pg\Mapper\CommentViewMapper;
use App\Shared\Infrastructure\Persistence\Pg\Mapper\ProfileViewMapper;
use PHPUnit\Framework\TestCase;

final class CommentViewMapperTest extends TestCase
{
    public function testARowBecomesACommentWithItsAuthor(): void
    {
        $comment = $this->mapper()->toView([
            'id' => '9',
            'body' => 'It takes a Jacobian',
            'created_at' => '2026-01-02 03:04:05.678123+00',
            'updated_at' => '2026-01-02 03:04:05.678123+00',
            'username' => 'jake',
            'bio' => null,
            'image' => null,
            'following' => 't',
        ]);

        self::assertSame(9, $comment->id);
        self::assertSame('It takes a Jacobian', $comment->body);
        self::assertSame('2026-01-02T03:04:05.678Z', $comment->createdAt->toIso8601());
        self::assertSame('jake', $comment->author->username);
        self::assertTrue($comment->author->following);
    }

    public function testRowsBecomeAListInTheirOrder(): void
    {
        $comments = $this->mapper()->toViewList([[
            'id' => '9',
            'body' => 'It takes a Jacobian',
            'created_at' => '2026-01-02 03:04:05.678123+00',
            'updated_at' => '2026-01-02 03:04:05.678123+00',
            'username' => 'jake',
            'bio' => null,
            'image' => null,
            'following' => 't',
        ], ['id' => '4'] + [
            'id' => '9',
            'body' => 'It takes a Jacobian',
            'created_at' => '2026-01-02 03:04:05.678123+00',
            'updated_at' => '2026-01-02 03:04:05.678123+00',
            'username' => 'jake',
            'bio' => null,
            'image' => null,
            'following' => 't',
        ]]);

        self::assertSame([9, 4], $comments->map(static fn ($comment): int => $comment->id));
    }

    public function testTheRowOfAnArticleWithoutCommentsIsNoComment(): void
    {
        $row = array_fill_keys(['id', 'body', 'created_at', 'updated_at', 'username', 'bio', 'image', 'following'], null);

        self::assertTrue($this->mapper()->toViewList([$row])->isEmpty());
    }

    private function mapper(): CommentViewMapper
    {
        return new CommentViewMapper(new ProfileViewMapper());
    }
}
