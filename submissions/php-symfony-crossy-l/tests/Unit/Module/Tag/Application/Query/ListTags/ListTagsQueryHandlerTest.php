<?php

declare(strict_types=1);

namespace App\Tests\Unit\Module\Tag\Application\Query\ListTags;

use App\Module\Tag\Application\Port\TagReadServiceInterface;
use App\Module\Tag\Application\Query\ListTags\ListTagsQuery;
use App\Module\Tag\Application\Query\ListTags\ListTagsQueryHandler;
use App\Module\Tag\Application\Result\TagsResult;
use App\Shared\Application\Policy\NoAuthRequired;
use PHPUnit\Framework\TestCase;
use ReflectionClass;

final class ListTagsQueryHandlerTest extends TestCase
{
    public function testDelegatesToTheReadService(): void
    {
        $result = new TagsResult(tags: []);
        $readService = $this->createMock(TagReadServiceInterface::class);
        $readService->expects(self::once())->method('listTags')->willReturn($result);

        self::assertSame($result, (new ListTagsQueryHandler($readService))->handle(new ListTagsQuery()));
    }

    public function testDeclaresThatNoAuthorizationIsRequiredAndWhy(): void
    {
        $attributes = (new ReflectionClass(ListTagsQueryHandler::class))->getAttributes(NoAuthRequired::class);

        self::assertCount(1, $attributes);
        self::assertNotSame('', $attributes[0]->newInstance()->reason);
    }
}
