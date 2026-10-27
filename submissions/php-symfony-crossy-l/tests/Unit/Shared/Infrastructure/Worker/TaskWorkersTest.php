<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Infrastructure\Worker;

use App\Shared\Infrastructure\Worker\TaskJob;
use App\Shared\Infrastructure\Worker\TaskWorkers;
use Closure;
use LogicException;
use PHPUnit\Framework\TestCase;

final class TaskWorkersTest extends TestCase
{
    public function testOutsideTheServerAJobRunsHere(): void
    {
        self::assertSame(42, (new TaskWorkers())->run(self::job(static fn (): int => 42)));
    }

    public function testATaskWorkerAnswersWithTheJobsValue(): void
    {
        self::assertSame(['value' => false], TaskWorkers::perform(self::job(static fn (): bool => false)));
    }

    public function testATaskWorkerAnswersWithTheErrorAJobThrowsInsteadOfThrowingIt(): void
    {
        $outcome = TaskWorkers::perform(self::job(static fn (): never => throw new LogicException('no')));

        self::assertSame(['error' => 'LogicException: no'], $outcome);
    }

    public function testATaskWorkerRefusesAnythingButAJob(): void
    {
        self::assertSame(['error' => 'not a task job'], TaskWorkers::perform('password_hash'));
    }

    /**
     * @template T
     *
     * @param Closure(): T $work
     *
     * @return TaskJob<T>
     */
    private static function job(Closure $work): TaskJob
    {
        return new readonly class ($work) implements TaskJob {
            public function __construct(private Closure $work)
            {
            }

            public function run(): mixed
            {
                return ($this->work)();
            }
        };
    }
}
