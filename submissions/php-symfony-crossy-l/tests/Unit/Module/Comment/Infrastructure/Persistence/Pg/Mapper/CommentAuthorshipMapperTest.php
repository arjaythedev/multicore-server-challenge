<?php

declare(strict_types=1);

namespace App\Tests\Unit\Module\Comment\Infrastructure\Persistence\Pg\Mapper;

use App\Module\Comment\Infrastructure\Persistence\Pg\Mapper\CommentAuthorshipMapper;
use PHPUnit\Framework\TestCase;

final class CommentAuthorshipMapperTest extends TestCase
{
    public function testTheCommentAndItsAuthorComeFromTheRow(): void
    {
        $authorship = (new CommentAuthorshipMapper())->toDomain(['id' => '9', 'author_id' => '42']);

        self::assertSame(9, $authorship->commentId);
        self::assertSame(42, $authorship->authorId);
    }
}
