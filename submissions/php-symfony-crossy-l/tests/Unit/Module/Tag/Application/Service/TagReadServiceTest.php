<?php

declare(strict_types=1);

namespace App\Tests\Unit\Module\Tag\Application\Service;

use App\Module\Tag\Application\Result\TagsResult;
use App\Module\Tag\Application\Service\TagReadService;
use App\Module\Tag\Application\UseCase\ListTags;
use PHPUnit\Framework\TestCase;

final class TagReadServiceTest extends TestCase
{
    public function testListTagsDelegatesToTheUseCase(): void
    {
        $expected = new TagsResult(tags: []);

        $useCase = $this->createMock(ListTags::class);
        $useCase->expects(self::once())->method('__invoke')->willReturn($expected);

        self::assertSame($expected, (new TagReadService($useCase))->listTags());
    }
}
