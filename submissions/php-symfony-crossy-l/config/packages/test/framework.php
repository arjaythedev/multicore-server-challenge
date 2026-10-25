<?php

declare(strict_types=1);

use Symfony\Component\DependencyInjection\Loader\Configurator\ContainerConfigurator;

return static function (ContainerConfigurator $container): void {
    // Lets a test read private services from the container.
    $container->extension('framework', ['test' => true]);
};
