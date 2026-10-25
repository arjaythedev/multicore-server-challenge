<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Server;

/**
 * How many client connections the server may hold: one open file each, so the limit on open files is the limit on
 * users.
 */
final class ConnectionLimit
{
    /** The most connections the server is set up for. */
    private const int MOST = 200000;

    /** Descriptors kept back from the connections: Postgres, the listening sockets and the runtime's own files. */
    private const int RESERVED = 1000;

    private const int LEAST = 1024;

    /**
     * @param int|string $openFiles the soft limit on open files, as posix_getrlimit() reports it: a number, or 'unlimited'
     */
    public static function forOpenFiles(int|string $openFiles): int
    {
        if (!\is_int($openFiles)) {
            return self::MOST;
        }

        return max(self::LEAST, min(self::MOST, $openFiles - self::RESERVED));
    }
}
