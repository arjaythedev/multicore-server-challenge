<?php

declare(strict_types=1);

namespace App\Tests\Fixture\Http;

use App\Shared\Application\Policy\AuthenticatedCallerPolicy;
use App\Shared\Domain\Security\CallerContext;
use RuntimeException;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpKernel\Attribute\AsController;
use Symfony\Component\Routing\Attribute\Route;

/**
 * Routes that exist only in the test environment, to exercise what the real routes will rely on:
 * the CallerContext argument, the authenticated-caller policy, and an exception nobody expects.
 */
#[AsController]
final class CallerProbeAction
{
    public function __construct(
        private readonly AuthenticatedCallerPolicy $policy,
    ) {
    }

    /** A route where signing in is optional, as on the article pages. */
    #[Route('/__test/optional', methods: ['GET'])]
    public function optional(CallerContext $caller): JsonResponse
    {
        return new JsonResponse(['viewer' => $caller->getViewerId(), 'token' => $caller->getToken()]);
    }

    /** A route that needs a signed-in caller, as on the feed. */
    #[Route('/__test/required', methods: ['GET'])]
    public function required(CallerContext $caller): JsonResponse
    {
        $this->policy->authorize($caller);

        return new JsonResponse(['viewer' => $caller->getViewerId()]);
    }

    #[Route('/__test/boom', methods: ['GET'])]
    public function boom(): never
    {
        throw new RuntimeException('something nobody expected');
    }

    /** A route with a variable, a query string and the caller, in an order of its own. */
    #[Route('/__test/echo/{word}', methods: ['GET', 'POST'])]
    public function echo(string $word, Request $request, CallerContext $caller): JsonResponse
    {
        return new JsonResponse([
            'word' => $word,
            'method' => $request->getMethod(),
            'query' => $request->query->all(),
            'viewer' => $caller->getViewerId(),
        ]);
    }

    /** A controller that returns something other than a response. */
    #[Route('/__test/not-a-response', methods: ['GET'])]
    public function notAResponse(): string
    {
        return 'text';
    }
}
