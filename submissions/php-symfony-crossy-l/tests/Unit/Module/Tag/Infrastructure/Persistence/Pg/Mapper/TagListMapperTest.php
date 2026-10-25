<?php

declare(strict_types=1);

namespace App\Tests\Unit\Module\Tag\Infrastructure\Persistence\Pg\Mapper;

use App\Module\Tag\Infrastructure\Persistence\Pg\Mapper\TagListMapper;
use PHPUnit\Framework\TestCase;

final class TagListMapperTest extends TestCase
{
    public function testTheArrayOfNamesBecomesAListInTheOrderItCameIn(): void
    {
        self::assertSame(['a b', 'c,d', 'e'], (new TagListMapper())->toDomain(['names' => '{"a b","c,d",e}'])->toArray());
    }

    public function testNoTagsComeBackAsNullAndAreAnEmptyList(): void
    {
        self::assertTrue((new TagListMapper())->toDomain(['names' => null])->isEmpty());
    }
}
