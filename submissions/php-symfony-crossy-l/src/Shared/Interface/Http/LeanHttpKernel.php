<?php

declare(strict_types=1);

namespace App\Shared\Interface\Http;

use App\Shared\Domain\Security\CallerContext;
use LogicException;
use Psr\Container\ContainerInterface;
use ReflectionMethod;
use ReflectionNamedType;
use Symfony\Component\DependencyInjection\Attribute\AutowireLocator;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\HttpKernelInterface;
use Symfony\Component\Routing\RouterInterface;
use Throwable;

/**
 * Takes a request to its controller and brings back the response: the route is matched with the compiled matcher,
 * the controller gets the request, the caller and the route's variables, and a throwable becomes the JSON error body.
 * It stands in for the framework's HttpKernel, which dispatches events and resolves arguments this application does
 * not use.
 */
final class LeanHttpKernel implements HttpKernelInterface
{
    /**
     * @param ContainerInterface $controllers every controller, by its class
     */
    public function __construct(
        private readonly RouterInterface $router,
        #[AutowireLocator('controller.service_arguments')]
        private readonly ContainerInterface $controllers,
        private readonly CallerContextFactory $callers,
        private readonly ErrorResponder $errors,
    ) {
    }

    /**
     * $type and $catch are fixed by the interface and unused.
     *
     * @SuppressWarnings("PHPMD.UnusedFormalParameter")
     * @SuppressWarnings("PHPMD.BooleanArgumentFlag")
     */
    public function handle(Request $request, int $type = self::MAIN_REQUEST, bool $catch = true): Response
    {
        try {
            $this->router->getContext()->setMethod($request->getMethod());

            return $this->call($this->router->match(self::path($request)), $request);
        } catch (Throwable $failure) {
            return $this->errors->respond($failure);
        }
    }

    /**
     * @param array<array-key, mixed> $route what the matcher returns: the controller and the route's variables
     */
    private function call(array $route, Request $request): Response
    {
        $controller = $route['_controller'] ?? null;

        if (!\is_string($controller)) {
            throw new LogicException('The matched route names no controller.');
        }

        // An invokable controller is named by its class, any other by its class and method.
        [$class, $method] = str_contains($controller, '::') ? explode('::', $controller, 2) : [$controller, '__invoke'];
        $service = $this->controllers->get($class);

        if (!\is_object($service) || !method_exists($service, $method)) {
            throw new LogicException(\sprintf('The controller "%s" does not exist.', $controller));
        }

        $arguments = [];

        foreach ((new ReflectionMethod($service, $method))->getParameters() as $parameter) {
            $type = $parameter->getType();
            $arguments[] = match ($type instanceof ReflectionNamedType ? $type->getName() : null) {
                Request::class => $request,
                CallerContext::class => $this->callers->fromRequest($request),
                default => $route[$parameter->getName()] ?? throw new LogicException(\sprintf('The route gives "%s" no value for $%s.', $controller, $parameter->getName())),
            };
        }

        $response = $service->{$method}(...$arguments);

        if (!$response instanceof Response) {
            throw new LogicException(\sprintf('The controller "%s" did not return a response.', $controller));
        }

        return $response;
    }

    /**
     * The path of the request, without its query string.
     */
    private static function path(Request $request): string
    {
        $path = explode('?', $request->getRequestUri(), 2)[0];

        return str_starts_with($path, '/') ? $path : $request->getPathInfo();
    }
}
