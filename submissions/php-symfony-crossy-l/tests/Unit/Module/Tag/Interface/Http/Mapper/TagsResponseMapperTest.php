<?php

declare(strict_types=1);

namespace App\Tests\Unit\Module\Tag\Interface\Http\Mapper;

use App\Module\Tag\Application\Result\TagsResult;
use App\Module\Tag\Interface\Http\Mapper\TagsResponseMapper;
use PHPUnit\Framework\TestCase;

final class TagsResponseMapperTest extends TestCase
{
    public function testMapsTheResultToTheNamesInOrder(): void
    {
        $result = new TagsResult(tags: ['a', 'b']);

        self::assertSame(['a', 'b'], (new TagsResponseMapper())->toResponse($result)->tags);
    }

    public function testNoTagsIsAnEmptyJsonArrayNotAnObject(): void
    {
        $response = (new TagsResponseMapper())->toResponse(new TagsResult(tags: []));

        self::assertSame('{"tags":[]}', json_encode($response));
    }
}
