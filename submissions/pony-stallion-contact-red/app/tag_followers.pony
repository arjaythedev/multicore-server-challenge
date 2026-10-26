class _TagFollowers
  embed _jobs: Array[_Job] = Array[_Job]

  new create(first: _Job ref) => _jobs.push(first)

  fun ref push(job: _Job ref) => _jobs.push(job)

  fun size(): USize => _jobs.size()

  fun ref jobs(): Iterator[_Job] => _jobs.values()

  fun values(): Iterator[_Job box] => _jobs.values()
