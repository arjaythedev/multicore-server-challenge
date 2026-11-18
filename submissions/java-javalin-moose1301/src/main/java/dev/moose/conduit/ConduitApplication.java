package dev.moose.conduit;

import dev.moose.conduit.config.ConduitConfig;

public class ConduitApplication {

    public static void main(String[] args) {
        new Conduit(ConduitConfig.fromEnvironment()).initialize();
    }

}
