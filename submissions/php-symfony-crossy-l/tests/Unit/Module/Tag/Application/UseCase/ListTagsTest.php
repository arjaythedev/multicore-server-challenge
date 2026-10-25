<?php

declare(strict_types=1);

namespace App\Tests\Unit\Module\Tag\Application\UseCase;

use App\Module\Tag\Application\Mapper\TagsResultMapper;
use App\Module\Tag\Application\UseCase\ListTags;
use App\Module\Tag\Domain\Model\TagList;
use App\Module\Tag\Domain\Repository\TagRepositoryInterface;
use PHPUnit\Framework\TestCase;

final class ListTagsTest extends TestCase
{
    public function testListsTheRepositorysTagsInTheOrderItGaveThem(): void
    {
        $repository = $this->createStub(TagRepositoryInterface::class);
        $repository->method('findAllOrderedByName')->willReturn(
            TagList::fromArray(['alpha', 'beta', 'gamma']),
        );

        $result = (new ListTags($repository, new TagsResultMapper()))();

        self::assertSame(['alpha', 'beta', 'gamma'], $result->tags);
    }

    public function testNoTagsIsAnEmptyList(): void
    {
        $repository = $this->createStub(TagRepositoryInterface::class);
        $repository->method('findAllOrderedByName')->willReturn(TagList::empty());

        self::assertSame([], (new ListTags($repository, new TagsResultMapper()))()->tags);
    }
}
