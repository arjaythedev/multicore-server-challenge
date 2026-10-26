use "collections"
use pg = "postgres"

actor \nodoc\ _PendingClient is _QueryClient
  be db_result(id: U64, result: pg.Result) => None
  be db_failed(id: U64, failure: _DBFailure) => None

class \nodoc\ _PendingJobsTest
  let _env: Env
  let _recipient: _Recipient
  var _histories: USize = 0
  var _empty_first: USize = 0
  var _empty_repeat: USize = 0
  var _exhausted_first: USize = 0
  var _exhausted_repeat: USize = 0
  var _empty_shifts: USize = 0
  var _empty_fronts: USize = 0
  var _full_fronts: USize = 0
  var _empty_values: USize = 0
  var _full_values: USize = 0
  var _zero_one: USize = 0
  var _partial_refills: USize = 0
  var _two_cycles: USize = 0
  var _drains: USize = 0
  var _refills: USize = 0

  new create(env: Env) ? =>
    _env = env
    _recipient = _Recipient(_PendingClient)
    _TagScanTest(env)?
    var width: USize = 1
    for length in Range[USize](0, 8) do
      for history in Range[USize](0, width) do
        let actions = Array[USize]
        var digits = history
        for index in Range[USize](0, length) do
          actions.push(digits % 4)
          digits = digits / 4
        end
        _history(actions)?
        _histories = _histories + 1
      end
      width = width * 4
    end
    _history([as USize: 0; 0; 1; 0; 1; 1; 0; 1])?
    _assert(_histories == 21_845)?
    _assert(_empty_first > 0)?
    _assert(_empty_repeat > 0)?
    _assert(_exhausted_first > 0)?
    _assert(_exhausted_repeat > 0)?
    _assert(_empty_shifts > 0)?
    _assert(_empty_fronts > 0)?
    _assert(_full_fronts > 0)?
    _assert(_empty_values > 0)?
    _assert(_full_values > 0)?
    _assert(_zero_one > 0)?
    _assert(_partial_refills > 0)?
    _assert(_two_cycles > 0)?
    _assert(_drains > 0)?
    _assert(_refills > 0)?
    _env.out.print("pending job model passed")

  fun ref _history(actions: Array[USize] box) ? =>
    let queue: _PendingJobs ref = _PendingJobs
    let model = Array[_Job]
    let removed = Array[_Job]
    var drained = false
    var drains: USize = 0
    var refills: USize = 0
    var partially_drained = false
    _check(queue, model, removed)?
    for action in actions.values() do
      match action
      | 0 =>
        let was_empty = model.size() == 0
        let partial_drain = partially_drained and not was_empty
        let job = _Job(_recipient, 1,
          pg.PreparedQuery("SELECT 1", _P.none()), 0, 0)
        queue.push(job)
        model.push(job)
        if was_empty then _zero_one = _zero_one + 1 end
        if partial_drain then _partial_refills = _partial_refills + 1 end
        if drained and was_empty then
          _refills = _refills + 1
          refills = refills + 1
        end
      | 1 =>
        if model.size() == 0 then
          _assert(try queue.shift()?; false else true end)?
          _empty_shifts = _empty_shifts + 1
        else
          let expected = model.delete(0)?
          let actual = queue.shift()?
          _assert(actual is expected)?
          removed.push(actual)
          _assert(actual._pending_next() is None)?
          partially_drained = model.size() > 0
          if model.size() == 0 then
            drained = true
            _drains = _drains + 1
            drains = drains + 1
          end
        end
      | 2 => _front(queue, model)?
      | 3 => _values(queue, model)?
      else _Unreachable()
      end
      _check(queue, model, removed)?
    end
    if (drains >= 2) and (refills > 0) then
      _two_cycles = _two_cycles + 1
    end

  fun ref _check(queue: _PendingJobs box, model: Array[_Job] box,
    removed: Array[_Job] box) ?
  =>
    _assert(queue.size() == model.size())?
    let endpoints = queue._test_endpoints()
    _assert(endpoints._3 == model.size())?
    if model.size() == 0 then
      _assert(endpoints._1 is None)?
      _assert(endpoints._2 is None)?
    else
      _assert(endpoints._1 is model(0)?)?
      _assert(endpoints._2 is model(model.size() - 1)?)?
      _assert((endpoints._2 as _Job box)._pending_next() is None)?
    end
    _front(queue, model)?
    _values(queue, model)?
    for job in removed.values() do
      _assert(job._pending_next() is None)?
    end

  fun ref _front(queue: _PendingJobs box, model: Array[_Job] box) ? =>
    if model.size() == 0 then
      _assert(try queue.front()?; false else true end)?
      _empty_fronts = _empty_fronts + 1
    else
      _assert(queue.front()? is model(0)?)?
      _full_fronts = _full_fronts + 1
    end

  fun ref _values(queue: _PendingJobs box, model: Array[_Job] box) ? =>
    let iterator = queue.values()
    for expected in model.values() do
      _assert(iterator.has_next())?
      _assert(iterator.next()? is expected)?
    end
    _assert(not iterator.has_next())?
    _assert(try iterator.next()?; false else true end)?
    if model.size() == 0 then _empty_first = _empty_first + 1
    else _exhausted_first = _exhausted_first + 1 end
    _assert(not iterator.has_next())?
    _assert(try iterator.next()?; false else true end)?
    if model.size() == 0 then _empty_repeat = _empty_repeat + 1
    else _exhausted_repeat = _exhausted_repeat + 1 end
    _assert(not iterator.has_next())?
    if model.size() == 0 then _empty_values = _empty_values + 1
    else _full_values = _full_values + 1 end

  fun _assert(condition: Bool, loc: SourceLoc = __loc) ? =>
    if not condition then
      _env.err.print(loc.file() + ":" + loc.line().string()
        + ": pending job assertion failed")
      error
    end
