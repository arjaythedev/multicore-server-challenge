package conduit.architecture;

import static com.tngtech.archunit.core.domain.JavaClass.Predicates.resideInAPackage;
import static com.tngtech.archunit.core.domain.JavaClass.Predicates.resideOutsideOfPackage;
import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.classes;
import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noClasses;

import com.tngtech.archunit.core.domain.JavaClasses;
import com.tngtech.archunit.core.importer.ClassFileImporter;
import com.tngtech.archunit.core.importer.ImportOption;
import org.junit.jupiter.api.Test;

class ArchitectureTest {
    private static final JavaClasses PRODUCTION = new ClassFileImporter()
        .withImportOption(ImportOption.Predefined.DO_NOT_INCLUDE_TESTS).importPackages("conduit");

    @Test
    void errorsDependOnlyOnJavaAndErrors() {
        classes().that().resideInAPackage("conduit.errors..").should().onlyDependOnClassesThat()
            .resideInAnyPackage("java..", "conduit.errors..").check(PRODUCTION);
    }

    @Test
    void domainDependsOnlyOnJavaDomainAndErrors() {
        classes().that().resideInAPackage("conduit.domain..").should().onlyDependOnClassesThat()
            .resideInAnyPackage("java..", "conduit.domain..", "conduit.errors..")
            .allowEmptyShould(true).check(PRODUCTION);
    }

    @Test
    void domainEntitiesAreEncapsulatedClassesNotRecords() {
        classes().that().resideInAPackage("conduit.domain..").and().areTopLevelClasses().should()
            .notBeRecords().andShould().haveOnlyPrivateConstructors().check(PRODUCTION);
    }

    @Test
    void contractsDependOnlyOnJavaDomainAndContracts() {
        classes().that().resideInAPackage("conduit.contracts..").should().onlyDependOnClassesThat()
            .resideInAnyPackage("java..", "conduit.domain..", "conduit.errors..",
                "conduit.contracts..")
            .check(PRODUCTION);
    }

    @Test
    void usecasesDependOnlyOnJavaDomainContractsAndUsecases() {
        classes().that().resideInAPackage("conduit.usecases..").should().onlyDependOnClassesThat()
            .resideInAnyPackage("java..", "conduit.domain..", "conduit.errors..",
                "conduit.contracts..", "conduit.usecases..")
            .check(PRODUCTION);
    }

    @Test
    void queriesDoNotDependOnCommandsOrWritePorts() {
        noClasses().that().resideInAPackage("conduit.usecases.queries..").should()
            .dependOnClassesThat().resideInAPackage("conduit.usecases.commands..")
            .check(PRODUCTION);
        noClasses().that().resideInAPackage("conduit.usecases.queries..").should()
            .dependOnClassesThat().haveFullyQualifiedName("conduit.contracts.UnitOfWork").orShould()
            .dependOnClassesThat().haveFullyQualifiedName("conduit.contracts.UnitOfWork$Context")
            .orShould().dependOnClassesThat().haveSimpleNameEndingWith("Repository").orShould()
            .dependOnClassesThat()
            .haveFullyQualifiedName("conduit.contracts.favorite.FavoriteStore").orShould()
            .dependOnClassesThat().haveFullyQualifiedName("conduit.contracts.follow.FollowStore")
            .check(PRODUCTION);
    }

    @Test
    void readersAndReadModelsDoNotDependOnDomainEntities() {
        noClasses().that().resideInAPackage("conduit.contracts..").and()
            .haveSimpleNameEndingWith("Reader").should().dependOnClassesThat()
            .resideInAPackage("conduit.domain..").check(PRODUCTION);
        noClasses().that().resideInAPackage("conduit.contracts..readmodel..").should()
            .dependOnClassesThat().resideInAPackage("conduit.domain..").check(PRODUCTION);
    }

    @Test
    void repositoriesDoNotDependOnReadModels() {
        noClasses().that().resideInAPackage("conduit.contracts..").and()
            .haveSimpleNameEndingWith("Repository").should().dependOnClassesThat()
            .resideInAPackage("conduit.contracts..readmodel..").check(PRODUCTION);
    }

    @Test
    void inboundDoesNotBypassUsecasesOrDependOnPersistence() {
        noClasses().that().resideInAPackage("conduit.adapters.inbound..").should()
            .dependOnClassesThat(resideInAPackage("conduit.contracts..")
                .and(resideOutsideOfPackage("conduit.contracts..readmodel..")))
            .check(PRODUCTION);
        noClasses().that().resideInAPackage("conduit.adapters.inbound..").should()
            .dependOnClassesThat()
            .resideInAnyPackage("conduit.adapters.outbound..", "conduit.wiring..", "conduit",
                "java.sql..", "javax.sql..", "org.jooq..", "org.postgresql..",
                "com.zaxxer.hikari..", "conduit.generated..")
            .check(PRODUCTION);
    }

    @Test
    void outboundDependsOnlyOnItsOwnCodeAndPersistenceContracts() {
        classes().that().resideInAPackage("conduit.adapters.outbound..").should()
            .onlyDependOnClassesThat()
            .resideInAnyPackage("java..", "javax.sql..", "conduit.domain..", "conduit.errors..",
                "conduit.contracts..", "conduit.adapters.outbound..",
                "conduit.generated.postgres.jooq..", "org.jooq..", "org.postgresql..",
                "com.zaxxer.hikari..", "org.reactivestreams..", "com.auth0.jwt..",
                "at.favre.lib.crypto.bcrypt..")
            .check(PRODUCTION);
    }

    @Test
    void generatedCodeIsConsumedOnlyByOutboundOrGeneratedCode() {
        classes().that().resideInAPackage("conduit.generated.postgres.jooq..").should()
            .onlyHaveDependentClassesThat()
            .resideInAnyPackage("conduit.adapters.outbound..", "conduit.generated.postgres.jooq..")
            .check(PRODUCTION);
    }
}
