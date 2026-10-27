<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Worker;

use RuntimeException;
use Swoole\Server;
use Throwable;

/**
 * Runs a job in one of Swoole's task workers, so that the worker serving requests keeps answering its other requests
 * meanwhile. Outside the server, in tests and console commands, the job runs here.
 */
#[SurvivesRequests(reason: 'Holds the server whose task workers it sends jobs to.')]
final class TaskWorkers
{
    private const float TIMEOUT = 30.0;

    private ?Server $server = null;

    public function attach(Server $server): void
    {
        $this->server = $server;
    }

    /**
     * @template T
     *
     * @param TaskJob<T> $job
     *
     * @return T
     */
    public function run(TaskJob $job): mixed
    {
        if ($this->server === null || !Coroutines::running()) {
            return $job->run();
        }

        $outcomes = $this->server->taskCo([$job], self::TIMEOUT);
        $outcome = \is_array($outcomes) ? ($outcomes[0] ?? false) : false;

        if (!\is_array($outcome) || !\array_key_exists('value', $outcome)) {
            throw new RuntimeException(\is_array($outcome) && \is_string($outcome['error'] ?? null) ? $outcome['error'] : 'the task worker did not answer');
        }

        /** @var T */
        return $outcome['value'];
    }

    /**
     * What a task worker answers: the job's value, or the error it threw, so that a job never ends the task worker.
     *
     * @return array{value: mixed}|array{error: string}
     */
    public static function perform(mixed $job): array
    {
        if (!$job instanceof TaskJob) {
            return ['error' => 'not a task job'];
        }

        try {
            return ['value' => $job->run()];
        } catch (Throwable $failure) {
            return ['error' => $failure::class . ': ' . $failure->getMessage()];
        }
    }
}
