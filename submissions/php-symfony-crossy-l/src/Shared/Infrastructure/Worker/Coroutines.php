<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Worker;

use Swoole\Coroutine;

/**
 * Whether the code is running inside one of Swoole's coroutines; tests and console commands are not.
 */
final class Coroutines
{
    public static function running(): bool
    {
        return class_exists(Coroutine::class, false) && Coroutine::getCid() > 0;
    }
}
