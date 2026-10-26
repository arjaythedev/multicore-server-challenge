class _PendingJobs
  var _head: (_Job ref | None) = None
  var _tail: (_Job ref | None) = None
  var _size: USize = 0

  fun ref push(job: _Job ref) =>
    // Each enqueue must receive a fresh job, never a previously removed job.
    match _tail
    | let tail: _Job ref => tail._pending_link(job)
    else _head = job
    end
    _tail = job
    _size = _size + 1

  fun ref shift(): _Job ref ? =>
    match _head
    | let head: _Job ref =>
      _head = head._pending_take_next()
      _size = _size - 1
      if _size == 0 then _tail = None end
      head
    else error
    end

  fun size(): USize => _size

  fun ref take_tags(limit: USize): (_TagFollowers ref | None) =>
    var followers: (_TagFollowers ref | None) = None
    var previous: (_Job ref | None) = None
    var current = _head
    var remaining = limit.min(31)
    var inspected: USize = 0
    while (remaining > 0) and (inspected < 31) do
      match current
      | let job: _Job ref =>
        inspected = inspected + 1
        if job.is_tags() then
          let next' = job._pending_take_next()
          match previous
          | let before: _Job ref => before._pending_link(next')
          else _head = next'
          end
          if _tail is job then _tail = previous end
          _size = _size - 1
          match followers
          | let jobs: _TagFollowers => jobs.push(job)
          else followers = _TagFollowers(job)
          end
          remaining = remaining - 1
          current = next'
        elseif job.scan_read then
          previous = job
          current = job._pending_next_ref()
        else break
        end
      else break
      end
    end
    followers

  fun front(): _Job box ? =>
    match _head
    | let head: _Job box => head
    else error
    end

  fun values(): Iterator[_Job box] => _PendingJobsIterator(_head)

  fun _test_endpoints(): (_Job box | None, _Job box | None, USize) =>
    (_head, _tail, _size)

class _PendingJobsIterator is Iterator[_Job box]
  var _next: (_Job box | None)

  new create(head: (_Job box | None)) => _next = head

  fun has_next(): Bool => _next isnt None

  fun ref next(): _Job box ? =>
    match _next
    | let job: _Job box =>
      _next = job._pending_next()
      job
    else error
    end
