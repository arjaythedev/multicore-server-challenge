<?php

declare(strict_types=1);

namespace App\Tests\PHPStan;

use PhpParser\Node;
use PhpParser\Node\Stmt\Class_;
use PHPStan\Analyser\Scope;
use PHPStan\Reflection\ReflectionProvider;
use PHPStan\Rules\IdentifierRuleError;
use PHPStan\Rules\Rule;
use PHPStan\Rules\RuleErrorBuilder;
use Symfony\Contracts\Service\ResetInterface;

/**
 * Keeps state out of the instances the container shares: a service holds nothing that changes, or declares it with
 * #[SurvivesRequests], or implements ResetInterface so the kernel empties it between requests.
 *
 * @implements Rule<Class_>
 */
final class MutableServiceStateRule implements Rule
{
    private const string SURVIVES_REQUESTS = 'App\\Shared\\Infrastructure\\Worker\\SurvivesRequests';

    /** Namespaces config/services.php excludes from autowiring: values built per request, not services. */
    private const array EXCLUDED_NAMESPACES = [
        '\\Domain\\Model\\',
        '\\Application\\Result\\',
        '\\Interface\\Http\\Response\\',
    ];

    public function __construct(
        private readonly ReflectionProvider $reflectionProvider,
    ) {
    }

    public function getNodeType(): string
    {
        return Class_::class;
    }

    /**
     * @return list<IdentifierRuleError>
     */
    public function processNode(Node $node, Scope $scope): array
    {
        if ($node->isReadonly()) {
            return [];
        }

        $className = $node->namespacedName?->toString();

        if ($className === null || !$this->isAService($className)) {
            return [];
        }

        if ($this->survivesRequestsOnPurpose($node) || $this->resetsItself($className)) {
            return [];
        }

        $mutable = $this->mutableProperties($node);

        if ($mutable === []) {
            return [];
        }

        return [
            RuleErrorBuilder::message(\sprintf(
                'Service %s keeps mutable state in $%s. The container hands every request the same '
                . 'instance, so what one request writes the next one reads. Make it readonly, mark it '
                . '#[SurvivesRequests] if it holds the worker\'s connection, or implement ResetInterface '
                . 'so the kernel empties it between requests.',
                $className,
                implode(', $', $mutable),
            ))->identifier('app.mutableServiceState')->build(),
        ];
    }

    private function survivesRequestsOnPurpose(Class_ $node): bool
    {
        foreach ($node->attrGroups as $attrGroup) {
            foreach ($attrGroup->attrs as $attr) {
                if ($attr->name->toString() === self::SURVIVES_REQUESTS) {
                    return true;
                }
            }
        }

        return false;
    }

    private function resetsItself(string $className): bool
    {
        if (!$this->reflectionProvider->hasClass($className)) {
            return false;
        }

        return $this->reflectionProvider->getClass($className)->implementsInterface(ResetInterface::class);
    }

    private function isAService(string $className): bool
    {
        if (!str_starts_with($className, 'App\\') || str_starts_with($className, 'App\\Tests\\')) {
            return false;
        }

        foreach (self::EXCLUDED_NAMESPACES as $namespace) {
            if (str_contains($className, $namespace)) {
                return false;
            }
        }

        return true;
    }

    /**
     * @return list<string>
     */
    private function mutableProperties(Class_ $node): array
    {
        $mutable = [];

        foreach ($node->getProperties() as $property) {
            if ($property->isReadonly()) {
                continue;
            }

            foreach ($property->props as $prop) {
                $mutable[] = $prop->name->toString();
            }
        }

        foreach ($node->getMethod('__construct')->params ?? [] as $param) {
            if ($param->flags === 0 || $param->isReadonly()) {
                continue;
            }

            if ($param->var instanceof Node\Expr\Variable && \is_string($param->var->name)) {
                $mutable[] = $param->var->name;
            }
        }

        return $mutable;
    }
}
