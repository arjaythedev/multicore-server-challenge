ThisBuild / scalaVersion := "3.10.0"

val nettyVersion = "4.2.19.Final"

lazy val stage = taskKey[File]("Copies the app jar and its runtime classpath into target/lib, which start.sh runs")

lazy val root = project
  .in(file("."))
  .settings(
    name := "multicore-conduit",
    version := "1.0.0",
    scalacOptions ++= Seq("-deprecation", "-feature", "-Wunused:all"),
    libraryDependencies ++= Seq(
      "io.netty" % "netty-transport" % nettyVersion,
      "io.netty" % "netty-handler" % nettyVersion,
      // Native transports for Linux (x86_64 on the benchmark box): io_uring and epoll. Elsewhere the server falls
      // back to NIO.
      ("io.netty" % "netty-transport-native-epoll" % nettyVersion)
        .classifier("linux-x86_64")
        .classifier("linux-aarch_64"),
      ("io.netty" % "netty-transport-native-io_uring" % nettyVersion)
        .classifier("linux-x86_64")
        .classifier("linux-aarch_64"),
      "org.scalameta" %% "munit" % "1.3.6" % Test,
      // Tests only, not in target/lib: the references the JSON parser and bcrypt are checked against.
      "com.fasterxml.jackson.core" % "jackson-databind" % "2.18.2" % Test,
      "org.springframework.security" % "spring-security-crypto" % "7.1.1" % Test,
    ),
    Test / fork := true,
    Test / javaOptions ++= Seq("--enable-native-access=ALL-UNNAMED", "--sun-misc-unsafe-memory-access=allow"),
    stage := {
      val dir = target.value / "lib"
      IO.delete(dir)
      val jars = (Runtime / fullClasspathAsJars).value.map(_.data)
      IO.copy(jars.map(jar => jar -> dir / jar.getName))
      streams.value.log.info(s"Staged ${jars.size} jars in $dir")
      dir
    },
  )
