<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Worker;

/**
 * CPU-bound work for a task worker. It is serialized on its way there, so it holds plain values only.
 *
 * @template T
 */
interface TaskJob
{
    /**
     * @return T
     */
    public function run(): mixed;
}
