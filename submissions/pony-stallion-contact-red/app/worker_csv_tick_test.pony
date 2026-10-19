use "time"

actor \nodoc\ _WorkerCSVTickTest is _WorkerCSVSource
  let _env: Env
  var _ticks: USize = 0

  new create(env: Env) =>
    _env = env
    let notify: _WorkerCSVTick ref = _WorkerCSVTick(this)
    let timer: Timer ref = Timer(_WorkerCSVTick(this), 1)
    notify.apply(timer, 5)
    this.check()

  be csv_tick() => _ticks = _ticks + 1

  be check() =>
    if _ticks == 1 then
      _env.out.print("CSV timer notification passed")
    else
      _env.err.print("Expected one CSV tick for coalesced expirations")
      _env.exitcode(1)
    end
