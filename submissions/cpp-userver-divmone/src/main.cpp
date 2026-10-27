#include <userver/clients/dns/component.hpp>
#include <userver/components/minimal_server_component_list.hpp>
#include <userver/storages/postgres/component.hpp>
#include <userver/testsuite/testsuite_support.hpp>
#include <userver/utils/daemon_run.hpp>

#include "handlers.hpp"

int main(int argc, char* argv[]) {
    namespace us = USERVER_NAMESPACE;
    const auto components = us::components::MinimalServerComponentList()
                                .Append<us::clients::dns::Component>()
                                .Append<us::components::TestsuiteSupport>()
                                .Append<us::components::Postgres>("conduit-db")
                                .Append<conduit::Register>()
                                .Append<conduit::Login>()
                                .Append<conduit::CurrentUser>()
                                .Append<conduit::Profile>()
                                .Append<conduit::Follow>()
                                .Append<conduit::Articles>()
                                .Append<conduit::Feed>()
                                .Append<conduit::Article>()
                                .Append<conduit::Favorite>()
                                .Append<conduit::Comments>()
                                .Append<conduit::Comment>()
                                .Append<conduit::Tags>();
    return us::utils::DaemonMain(argc, argv, components);
}
