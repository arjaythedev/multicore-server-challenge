use pg = "postgres"

class val _ConnectionPasswordWait
  let id: U64
  let hash: Bool
  new val create(id': U64, hash': Bool) =>
    id = id'
    hash = hash'

class val _StartApplication
  let id: U64
  new val create(id': U64) => id = id'
  fun apply(connection: _Connection ref) => connection._start_application(id)

class val _DatabaseApplicationResult
  let id: U64
  let result: pg.Result
  new val create(id': U64, result': pg.Result) =>
    id = id'
    result = result'
  fun apply(connection: _Connection ref) =>
    connection._result_application(id, result)

class val _DatabaseApplicationFailure
  let id: U64
  let failure: _DBFailure
  new val create(id': U64, failure': _DBFailure) =>
    id = id'
    failure = failure'
  fun apply(connection: _Connection ref) =>
    connection._failed_application(id, failure)

primitive _CloseApplication
  fun apply(connection: _Connection ref) => connection._close_application()

type _ApplicationEvent is
  (_StartApplication | _DatabaseApplicationResult |
    _DatabaseApplicationFailure | _CloseApplication)
