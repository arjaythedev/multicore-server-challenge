class _TagFollowers
  embed _jobs: Array[_Job] = Array[_Job]

  new create(pending: _PendingJobs ref, limit: USize) =>
    var remaining = limit
    while (remaining > 0) and (pending.size() > 0) do
      try
        if not pending.front()?.is_tags() then break end
        _jobs.push(pending.shift()?)
        remaining = remaining - 1
      else _Unreachable() end
    end

  fun size(): USize => _jobs.size()

  fun ref jobs(): Iterator[_Job] => _jobs.values()

  fun values(): Iterator[_Job box] => _jobs.values()
