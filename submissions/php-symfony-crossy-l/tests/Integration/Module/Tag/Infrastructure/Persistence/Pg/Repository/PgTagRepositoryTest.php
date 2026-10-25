<?php

declare(strict_types=1);

namespace App\Tests\Integration\Module\Tag\Infrastructure\Persistence\Pg\Repository;

use App\Module\Tag\Infrastructure\Persistence\Pg\Repository\PgTagRepository;
use App\Tests\Integration\Shared\Trait\RunsInRolledBackTransaction;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;

final class PgTagRepositoryTest extends KernelTestCase
{
    use RunsInRolledBackTransaction;

    public function testListsEverySeededTagSortedByName(): void
    {
        $names = $this->names();

        self::assertCount(200, $names);
        $sorted = $names;
        sort($sorted, SORT_STRING);
        self::assertSame($sorted, $names);
        self::assertContains('baviot', $names);
    }

    public function testASortsBeforeEverythingAndZAfter(): void
    {
        $this->connection->write('INSERT INTO tags (name) VALUES ($1), ($2)', ['0-first-tag', 'zzz-last-tag']);

        $names = $this->names();

        self::assertCount(202, $names);
        self::assertSame('0-first-tag', $names[0]);
        self::assertSame('zzz-last-tag', $names[201]);
    }

    public function testAnEmptyTableIsAnEmptyList(): void
    {
        $this->connection->write('DELETE FROM article_tags', []);
        $this->connection->write('DELETE FROM tags', []);

        self::assertTrue($this->repository()->findAllOrderedByName()->isEmpty());
    }

    private function repository(): PgTagRepository
    {
        $repository = self::getContainer()->get(PgTagRepository::class);
        self::assertInstanceOf(PgTagRepository::class, $repository);

        return $repository;
    }

    /**
     * @return list<string>
     */
    private function names(): array
    {
        return $this->repository()->findAllOrderedByName()->toArray();
    }
}
