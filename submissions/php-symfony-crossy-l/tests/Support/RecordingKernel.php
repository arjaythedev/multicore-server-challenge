<?php

declare(strict_types=1);

namespace App\Tests\Support;

use RuntimeException;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\HttpKernelInterface;
use Symfony\Component\HttpKernel\TerminableInterface;

/**
 * A kernel that answers every path with the path, throws for /boom, and remembers what it was asked to
 * handle and to terminate.
 */
final class RecordingKernel implements HttpKernelInterface, TerminableInterface
{
    /** @var list<string> */
    public array $handled = [];

    /** @var list<string> */
    public array $terminated = [];

    public function handle(Request $request, int $type = self::MAIN_REQUEST, bool $catch = true): Response
    {
        $this->handled[] = $request->getPathInfo();

        if ($request->getPathInfo() === '/boom') {
            throw new RuntimeException('boom');
        }

        return new Response($request->getPathInfo());
    }

    public function terminate(Request $request, Response $response): void
    {
        $this->terminated[] = $request->getPathInfo();
    }
}
