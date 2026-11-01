#include <cstdlib>
#include <cstdio>
#include <string>
#include <memory>
#include <unistd.h>
#include <climits>
#include <csignal>

#include <drogon/drogon.h>
#include <drogon/orm/DbClient.h>

#include "controllers/UsersController.hpp"
#include "controllers/ProfilesController.hpp"
#include "controllers/ArticlesController.hpp"
#include "controllers/FavoritesController.hpp"
#include "controllers/CommentsController.hpp"
#include "controllers/TagsController.hpp"
#include "middleware/AuthCheckMiddleware.hpp"
#include "controllers/Common.hpp"

static std::string exeDir()
{
    char buf[PATH_MAX];
    const ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n <= 0) return ".";
    buf[n] = '\0';
    std::string p(buf);
    const auto slash = p.find_last_of('/');
    return (slash == std::string::npos) ? "." : p.substr(0, slash);
}

static const char* envOr(const char* name, const char* def) {
    const char* v = std::getenv(name);
    return (v && *v) ? v : def;
}

static int envInt(const char* name, int def) {
    const char* v = std::getenv(name);
    if (!v || !*v) return def;
    try { return std::stoi(v); } catch (...) { return def; }
}

static void primeSessionSettings(const drogon::orm::DbClientPtr& db, int conns)
{
    static auto kSet =
        "SET jit = off;"
        "SET max_parallel_workers_per_gather = 0;"
        "SET enable_memoize = off;"
        "SET synchronous_commit = on;";

    if (!db) return;
    for (int i = 0; i < conns * 2 + 4; ++i)
    {
        try { db->execSqlSync(kSet); }
        catch (...) { /* ignore */ }
    }
}

int main()
{
    ::signal(SIGPIPE, SIG_IGN);

    const std::string appCfg = exeDir() + "/config/config.json";
    drogon::app().loadConfigFile(appCfg);

    drogon::app().setIdleConnectionTimeout(120);
    drogon::app().setClientMaxBodySize(1024 * 1024);
    drogon::app().setClientMaxMemoryBodySize(64 * 1024);

    drogon::app().setCustom404Page(
        multicore::common::MakeError(drogon::k404NotFound, "Not found"), true);

    drogon::app().enableServerHeader(false);
    drogon::app().enableDateHeader(false);
    drogon::app().disableSigtermHandling();

    const char* host = envOr("HOST", "127.0.0.1");
    const char* port = envOr("PORT", "3000");
    drogon::app().addListener(host, std::stoi(port));

    const char* url = std::getenv("DATABASE_URL");
    if (!url || !*url) {
        std::fprintf(stderr, "DATABASE_URL is required\n");
        return 1;
    }

    // postgres://user:pass@host:port/dbname
    const std::string u(url);
    const auto proto = u.find("://");
    if (proto == std::string::npos) {
        std::fprintf(stderr, "bad DATABASE_URL\n");
        return 1;
    }

    std::string rest = u.substr(proto + 3);
    auto at = rest.find('@');
    auto slash = rest.find('/', at == std::string::npos ? 0 : at);
    if (at == std::string::npos || slash == std::string::npos) {
        std::fprintf(stderr, "bad DATABASE_URL\n");
        return 1;
    }

    std::string userinfo = rest.substr(0, at);
    std::string hostport = rest.substr(at + 1, slash - at - 1);
    std::string dbname   = rest.substr(slash + 1);

    std::string user = userinfo, pass;
    auto colon = userinfo.find(':');
    if (colon != std::string::npos) {
        user = userinfo.substr(0, colon);
        pass = userinfo.substr(colon + 1);
    }
    std::string dbhost = hostport, dbport = "5432";
    auto c2 = hostport.find(':');
    if (c2 != std::string::npos) {
        dbhost = hostport.substr(0, c2);
        dbport = hostport.substr(c2 + 1);
    }

    const int readConns  = envInt("DB_READ_CONNS",  12);
    const int writeConns = envInt("DB_WRITE_CONNS", 16);

    drogon::orm::PostgresConfig base;
    base.host             = dbhost;
    base.port             = static_cast<unsigned short>(std::stoi(dbport));
    base.databaseName     = dbname;
    base.username         = user;
    base.password         = pass;
    base.characterSet     = "UTF8";
    base.timeout          = 0.0;
    base.autoBatch        = false;

    drogon::orm::PostgresConfig readCfg = base;
    readCfg.name             = "default";
    readCfg.isFast           = false;
    readCfg.connectionNumber = readConns;
    drogon::app().addDbClient(readCfg);

    drogon::orm::PostgresConfig writeCfg = base;
    writeCfg.name             = "write";
    writeCfg.isFast           = false;
    writeCfg.connectionNumber = writeConns;
    drogon::app().addDbClient(writeCfg);

    auto readDb  = drogon::app().getDbClient();
    auto writeDb = drogon::app().getDbClient("write");

    primeSessionSettings(readDb,  readConns);
    primeSessionSettings(writeDb, writeConns);

    drogon::app().registerMiddleware(std::make_shared<multicore::AuthRequiredMiddleware>());
    drogon::app().registerMiddleware(std::make_shared<multicore::AuthOptionalMiddleware>());
    drogon::app().registerController(std::make_shared<multicore::UsersController>());
    drogon::app().registerController(std::make_shared<multicore::ProfilesController>());
    drogon::app().registerController(std::make_shared<multicore::ArticlesController>());
    drogon::app().registerController(std::make_shared<multicore::FavoritesController>());
    drogon::app().registerController(std::make_shared<multicore::CommentsController>());
    drogon::app().registerController(std::make_shared<multicore::TagsController>());

    drogon::app().run();
    return 0;
}