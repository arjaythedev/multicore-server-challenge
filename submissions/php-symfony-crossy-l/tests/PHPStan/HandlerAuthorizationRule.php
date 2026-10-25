<?php

declare(strict_types=1);

namespace App\Tests\PHPStan;

use PhpParser\Node;
use PhpParser\Node\Expr\MethodCall;
use PhpParser\Node\Stmt\Class_;
use PhpParser\NodeFinder;
use PHPStan\Analyser\Scope;
use PHPStan\Rules\IdentifierRuleError;
use PHPStan\Rules\Rule;
use PHPStan\Rules\RuleErrorBuilder;

/**
 * Every class named *CommandHandler or *QueryHandler declares #[AuthorizationPolicy] or #[NoAuthRequired] at the
 * class level, and one that claims a policy calls it.
 *
 * @implements Rule<Class_>
 */
final class HandlerAuthorizationRule implements Rule
{
    private const array POLICY_ATTRIBUTES = [
        'AuthorizationPolicy',
        'App\\Shared\\Application\\Policy\\AuthorizationPolicy',
    ];

    private const array EXEMPT_ATTRIBUTES = [
        'NoAuthRequired',
        'App\\Shared\\Application\\Policy\\NoAuthRequired',
    ];

    public function getNodeType(): string
    {
        return Class_::class;
    }

    /**
     * @return list<IdentifierRuleError>
     */
    public function processNode(Node $node, Scope $scope): array
    {
        $className = $node->name?->toString();

        if ($className === null || !$this->isHandler($className)) {
            return [];
        }

        $declared = $this->declaredAttributes($node);

        if (array_intersect($declared, self::EXEMPT_ATTRIBUTES) !== []) {
            return [];
        }

        if (array_intersect($declared, self::POLICY_ATTRIBUTES) === []) {
            return [
                RuleErrorBuilder::message(\sprintf(
                    'Handler class %s must declare #[AuthorizationPolicy] or #[NoAuthRequired].',
                    $className,
                ))->identifier('app.handlerAuthorization.missingAttribute')->build(),
            ];
        }

        if ($this->callsAuthorize($node)) {
            return [];
        }

        return [
            RuleErrorBuilder::message(\sprintf(
                'Handler class %s declares #[AuthorizationPolicy] but never calls authorize().',
                $className,
            ))->identifier('app.handlerAuthorization.neverAuthorizes')->build(),
        ];
    }

    private function isHandler(string $className): bool
    {
        return str_ends_with($className, 'CommandHandler') || str_ends_with($className, 'QueryHandler');
    }

    /**
     * @return list<string>
     */
    private function declaredAttributes(Class_ $node): array
    {
        $names = [];

        foreach ($node->attrGroups as $attrGroup) {
            foreach ($attrGroup->attrs as $attr) {
                $names[] = $attr->name->toString();
            }
        }

        return $names;
    }

    private function callsAuthorize(Class_ $node): bool
    {
        /** @var list<MethodCall> $calls */
        $calls = (new NodeFinder())->findInstanceOf($node->stmts, MethodCall::class);

        foreach ($calls as $call) {
            if ($call->name instanceof Node\Identifier && $call->name->toString() === 'authorize') {
                return true;
            }
        }

        return false;
    }
}
