<?php

declare(strict_types=1);

namespace App\Tests\Integration\Shared\Trait;

use App\Shared\Infrastructure\Persistence\Pg\PgConnection;
use PHPUnit\Framework\Attributes\After;
use PHPUnit\Framework\Attributes\Before;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;

/**
 * Runs each test of a KernelTestCase inside a transaction on the kernel's own Postgres connection and
 * rolls it back afterwards, so a test sees what it wrote through the application's code and leaves
 * nothing behind.
 *
 * @phpstan-require-extends KernelTestCase
 */
trait RunsInRolledBackTransaction
{
    protected PgConnection $connection;

    #[Before]
    protected function beginTransaction(): void
    {
        self::bootKernel();

        $connection = self::getContainer()->get(PgConnection::class);
        self::assertInstanceOf(PgConnection::class, $connection);

        $this->connection = $connection;
        $this->connection->write('BEGIN', []);
    }

    #[After]
    protected function rollBack(): void
    {
        $this->connection->write('ROLLBACK', []);
    }
}
