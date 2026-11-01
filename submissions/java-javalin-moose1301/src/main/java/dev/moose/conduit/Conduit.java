package dev.moose.conduit;

import dev.moose.conduit.auth.JwtService;
import dev.moose.conduit.auth.password.PasswordService;
import dev.moose.conduit.config.ConduitConfig;
import dev.moose.conduit.database.DatabaseService;
import dev.moose.conduit.http.HttpService;
import dev.moose.conduit.read.ReadService;
import dev.moose.conduit.write.WriteService;
import lombok.Getter;

import java.util.concurrent.ForkJoinPool;

@Getter
public class Conduit {

    private static Conduit instance;

    private final ConduitConfig config;
    private final ForkJoinPool responder;

    private DatabaseService databaseService;
    private JwtService jwtService;
    private PasswordService passwordService;
    private ReadService readService;
    private WriteService writeService;
    private HttpService httpService;

    public Conduit(ConduitConfig config) {
        instance = this;

        this.config = config;
        this.responder = new ForkJoinPool(config.getCores(), ForkJoinPool.defaultForkJoinWorkerThreadFactory, null, true);
    }

    public void initialize() {
        PasswordService.selfCheck();

        this.databaseService = new DatabaseService(this.config.getDatabaseUrl());
        this.jwtService = new JwtService(this.config.getJwtSecret());
        this.passwordService = new PasswordService(this.config, this.responder);
        this.readService = new ReadService(this.databaseService, this.config, this.responder);
        this.writeService = new WriteService(this.databaseService, this.config, this.responder, this.jwtService);
        this.httpService = new HttpService(this.config);

        this.httpService.start();
    }

    public static Conduit get() {
        return instance;
    }

}
