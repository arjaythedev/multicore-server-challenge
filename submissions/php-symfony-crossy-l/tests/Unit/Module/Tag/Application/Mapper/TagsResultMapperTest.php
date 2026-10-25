<?php

declare(strict_types=1);

namespace App\Tests\Unit\Module\Tag\Application\Mapper;

use App\Module\Tag\Application\Mapper\TagsResultMapper;
use App\Module\Tag\Domain\Model\TagList;
use PHPUnit\Framework\TestCase;

final class TagsResultMapperTest extends TestCase
{
    public function testMapsAListToItsNamesKeepingTheOrder(): void
    {
        $result = (new TagsResultMapper())->toResult(TagList::fromArray(['b', 'a', 'b']));

        self::assertSame(['b', 'a', 'b'], $result->tags);
    }

    public function testNoTagsIsAnEmptyList(): void
    {
        self::assertSame([], (new TagsResultMapper())->toResult(TagList::empty())->tags);
    }
}
