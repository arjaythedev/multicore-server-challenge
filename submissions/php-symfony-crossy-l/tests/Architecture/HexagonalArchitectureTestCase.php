<?php

declare(strict_types=1);

namespace App\Tests\Architecture;

use PHPat\Selector\Selector;
use PHPat\Selector\SelectorInterface;
use PHPat\Test\Attributes\TestRule;
use PHPat\Test\Builder\Rule;
use PHPat\Test\PHPat;

/**
 * The layer and module boundaries, checked by PHPStan (task stan) through PHPat.
 *
 * Dependencies point inward: Interface and Infrastructure may use Application, Application may use
 * Domain, and Domain uses nothing but itself. Framework and driver classes stay in the outer layers.
 */
final class HexagonalArchitectureTestCase
{
    /**
     * Every feature module; each is a leaf.
     */
    private const array MODULES = ['Article', 'Comment', 'Profile', 'Tag', 'User'];

    /** Classes of the outer world, which only Infrastructure and Interface may name. */
    private const array FRAMEWORK_NAMESPACES = ['Symfony', 'Psr'];

    /** Classes of the database driver, which only Infrastructure may name. */
    private const array DRIVER_NAMESPACES = ['PgSql'];

    #[TestRule]
    public function testDomainDependsOnNothingOutsideItself(): Rule
    {
        return PHPat::rule()
            ->classes(...self::domain())
            ->shouldNotDependOn()
            ->classes(
                ...self::application(),
                ...self::infrastructure(),
                ...self::interface(),
                ...self::namespaces(...self::FRAMEWORK_NAMESPACES, ...self::DRIVER_NAMESPACES),
            )
            ->because('Domain is the innermost layer: no framework, no driver, no use case, no HTTP.');
    }

    #[TestRule]
    public function testApplicationDoesNotDependOnTheOuterLayers(): Rule
    {
        return PHPat::rule()
            ->classes(...self::application())
            ->shouldNotDependOn()
            ->classes(
                ...self::infrastructure(),
                ...self::interface(),
                ...self::namespaces(...self::FRAMEWORK_NAMESPACES, ...self::DRIVER_NAMESPACES),
            )
            ->because('Application depends on Domain and on itself; ports and results are what it shows the outside.');
    }

    #[TestRule]
    public function testInterfaceDoesNotDependOnInfrastructureOrDrivers(): Rule
    {
        return PHPat::rule()
            ->classes(...self::interface())
            ->shouldNotDependOn()
            ->classes(...self::infrastructure(), ...self::namespaces(...self::DRIVER_NAMESPACES))
            ->because('Interface reaches the data only through Application ports.');
    }

    #[TestRule]
    public function testInfrastructureDoesNotDependOnInterface(): Rule
    {
        return PHPat::rule()
            ->classes(...self::infrastructure())
            ->shouldNotDependOn()
            ->classes(...self::interface())
            ->because('Infrastructure implements Domain ports; it knows nothing of HTTP.');
    }

    #[TestRule]
    public function testSharedDoesNotDependOnAnyModule(): Rule
    {
        return PHPat::rule()
            ->classes(Selector::inNamespace('App\\Shared'))
            ->shouldNotDependOn()
            ->classes(Selector::inNamespace('App\\Module'))
            ->because('Shared is the kernel every module builds on; dependencies point in to it, never back out.');
    }

    #[TestRule]
    public function testOnlyPersistenceTouchesPostgres(): Rule
    {
        return PHPat::rule()
            ->classes(Selector::inNamespace('App'))
            ->excluding(
                Selector::inNamespace('App\\Shared\\Infrastructure\\Persistence'),
                Selector::inNamespace('/^App\\\\Module\\\\[^\\\\]+\\\\Infrastructure\\\\Persistence(\\\\|$)/', true),
                Selector::classname('App\\Shared\\Infrastructure\\Worker\\OpenWorkerConnections'),
                Selector::inNamespace('App\\Tests'),
            )
            ->shouldNotDependOn()
            ->classes(Selector::inNamespace('PgSql'), Selector::classname('App\\Shared\\Infrastructure\\Persistence\\Pg\\PgConnection'))
            ->because('The connection and its result objects stay behind the repositories.');
    }

    /**
     * Each module depends on no other module.
     *
     * @return iterable<string, Rule>
     */
    #[TestRule]
    public function testModulesDoNotDependOnEachOther(): iterable
    {
        foreach (self::MODULES as $module) {
            $others = array_values(array_diff(self::MODULES, [$module]));

            yield $module => PHPat::rule()
                ->classes(self::moduleNamespace($module))
                ->shouldNotDependOn()
                ->classes(...array_map(self::moduleNamespace(...), $others))
                ->because(\sprintf('%s is a leaf module; a read across tables is one statement in the module that serves it.', $module));
        }
    }

    /**
     * A module is used by others only through its published surface: ports, results and domain models.
     *
     * @return iterable<string, Rule>
     */
    #[TestRule]
    public function testModulesAreConsumedOnlyThroughTheirPublishedSurface(): iterable
    {
        foreach (self::MODULES as $module) {
            yield $module => PHPat::rule()
                ->classes(Selector::inNamespace('App'))
                ->excluding(self::moduleNamespace($module), Selector::inNamespace('App\\Tests'))
                ->shouldNotDependOn()
                ->classes(...self::internalSurface($module))
                ->because(\sprintf('%s may be consumed through Application\\Port, Application\\Result and Domain\\Model only.', $module));
        }
    }

    /**
     * What a module's ports mention is part of the surface, so none of it may be internal.
     *
     * @return iterable<string, Rule>
     */
    #[TestRule]
    public function testPortsMentionOnlyPublishedTypes(): iterable
    {
        foreach (self::MODULES as $module) {
            yield $module => PHPat::rule()
                ->classes(Selector::inNamespace(\sprintf('App\\Module\\%s\\Application\\Port', $module)))
                ->shouldNotDependOn()
                ->classes(...self::internalSurface($module))
                ->because(\sprintf('A %s port is its published contract; it may name only published types.', $module));
        }
    }

    private static function moduleNamespace(string $module): SelectorInterface
    {
        return Selector::inNamespace('App\\Module\\' . $module);
    }

    /**
     * Everything in a module that other modules must not touch.
     *
     * @return list<SelectorInterface>
     */
    private static function internalSurface(string $module): array
    {
        $base = 'App\\Module\\' . $module . '\\';

        return array_map(
            static fn (string $namespace): SelectorInterface => Selector::inNamespace($base . $namespace),
            [
                'Application\\Service',
                'Application\\UseCase',
                'Application\\Command',
                'Application\\Query',
                'Application\\Policy',
                'Application\\Mapper',
                'Domain\\Repository',
                'Domain\\Service',
                'Domain\\Factory',
                'Infrastructure',
                'Interface',
            ],
        );
    }

    /**
     * @param non-empty-string ...$namespaces
     *
     * @return list<SelectorInterface>
     */
    private static function namespaces(string ...$namespaces): array
    {
        return array_values(array_map(
            static fn (string $namespace): SelectorInterface => Selector::inNamespace($namespace),
            $namespaces,
        ));
    }

    /**
     * @return list<SelectorInterface>
     */
    private static function domain(): array
    {
        return [
            Selector::inNamespace('App\\Shared\\Domain'),
            Selector::inNamespace('/^App\\\\Module\\\\[^\\\\]+\\\\Domain(\\\\|$)/', true),
        ];
    }

    /**
     * @return list<SelectorInterface>
     */
    private static function application(): array
    {
        return [
            Selector::inNamespace('App\\Shared\\Application'),
            Selector::inNamespace('/^App\\\\Module\\\\[^\\\\]+\\\\Application(\\\\|$)/', true),
        ];
    }

    /**
     * @return list<SelectorInterface>
     */
    private static function infrastructure(): array
    {
        return [
            Selector::inNamespace('App\\Shared\\Infrastructure'),
            Selector::inNamespace('/^App\\\\Module\\\\[^\\\\]+\\\\Infrastructure(\\\\|$)/', true),
        ];
    }

    /**
     * @return list<SelectorInterface>
     */
    private static function interface(): array
    {
        return [
            Selector::inNamespace('App\\Shared\\Interface'),
            Selector::inNamespace('/^App\\\\Module\\\\[^\\\\]+\\\\Interface(\\\\|$)/', true),
        ];
    }
}
