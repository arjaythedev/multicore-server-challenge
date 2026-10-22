interface tag _PasswordApplicationObserver
  be application_accepted(connection: _Connection, id: U64, queued: Bool,
    epoch: U64, pending: Array[U64] val)
  be application_wait(connection: _Connection, id: U64, hash: Bool)
  be application_database(connection: _Connection, id: U64, queued: Bool)
  be application_physical_close(connection: _Connection, operations: USize,
    responders: USize, body: USize)
  be application_state(connection: _Connection, request: U64,
    accepted: U64, operations: USize, responders: USize, body: USize,
    pending: USize,
    waiting: U64, hash: Bool, closed: Bool)
  be application_paused(connection: _Connection, epoch: U64,
    pending: Array[U64] val)
  be application_logical_close(connection: _Connection)
  be application_sql(client: _QueryClient, id: U64, kind: USize)
  be application_cancel(client: _QueryClient)
  be application_fence(client: _QueryClient, request: U64)

interface tag _PasswordStartupObserver is _PasswordObserver
  be password_startup(mode: _PasswordMode, workers: USize,
    passwords: (_PasswordDispatcher | None))
  be password_server(workers: Array[_Worker] val, listener: _Listener)
  be password_listener_closed()
