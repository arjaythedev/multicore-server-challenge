<?php

declare(strict_types=1);

use Symfony\Component\DependencyInjection\Loader\Configurator\ContainerConfigurator;

return static function (ContainerConfigurator $container): void {
    // The compiled container creates each service from one method, with the classes it needs
    // loaded up front, rather than through the autoloader on first use.
    $container->parameters()
        ->set('container.dumper.inline_factories', true)
        ->set('container.dumper.inline_class_loader', true);
};
