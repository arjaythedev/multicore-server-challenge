<?php

// What PHPStan needs to know of the Swoole classes the code under src/ names. The extension provides the real ones.

declare(strict_types=1);

namespace {
    const SWOOLE_EVENT_READ = 512;
}

namespace Swoole {
    class Server
    {
        /**
         * @param list<mixed> $tasks
         *
         * @return array<int, mixed>|false
         */
        public function taskCo(array $tasks, float $timeout = 0.5): array|false
        {
            return [];
        }
    }

    class Coroutine
    {
        public static function getCid(): int
        {
            return -1;
        }

        public static function getContext(?int $cid = null): \ArrayObject
        {
            return new \ArrayObject();
        }

        public static function create(callable $function, mixed ...$args): int|false
        {
            return 1;
        }
    }
}

namespace Swoole\Coroutine {
    class Channel
    {
        public function __construct(int $capacity = 1)
        {
        }

        public function push(mixed $data, float $timeout = -1): bool
        {
            return true;
        }

        public function pop(float $timeout = -1): mixed
        {
            return null;
        }

        public function length(): int
        {
            return 0;
        }

        /**
         * @return array{consumer_num: int, producer_num: int, queue_num: int}
         */
        public function stats(): array
        {
            return ['consumer_num' => 0, 'producer_num' => 0, 'queue_num' => 0];
        }
    }

    class System
    {
        /**
         * @param resource|int $socket
         */
        public static function waitEvent(mixed $socket, int $events = SWOOLE_EVENT_READ, float $timeout = -1): int|false
        {
            return 0;
        }
    }
}
