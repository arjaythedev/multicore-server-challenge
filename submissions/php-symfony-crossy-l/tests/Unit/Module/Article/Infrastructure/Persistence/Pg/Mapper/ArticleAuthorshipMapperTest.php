<?php

declare(strict_types=1);

namespace App\Tests\Unit\Module\Article\Infrastructure\Persistence\Pg\Mapper;

use App\Module\Article\Infrastructure\Persistence\Pg\Mapper\ArticleAuthorshipMapper;
use PHPUnit\Framework\TestCase;

final class ArticleAuthorshipMapperTest extends TestCase
{
    public function testTheArticleAndItsAuthorComeFromTheRow(): void
    {
        $authorship = (new ArticleAuthorshipMapper())->toDomain(['id' => '7', 'author_id' => '42']);

        self::assertSame(7, $authorship->articleId);
        self::assertSame(42, $authorship->authorId);
    }
}
