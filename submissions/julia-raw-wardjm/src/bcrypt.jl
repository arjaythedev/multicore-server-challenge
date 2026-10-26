# bcrypt (cost 10) on worker threads of its own, so hashing never stalls an event loop. Loops queue jobs here; a
# worker takes up to four, runs them interleaved (blowfish.jl), posts each finished request back to its loop's done
# queue and wakes the loop through its eventfd. Like group commit, a worker holding fewer than four jobs waits a
# short while for more before it starts: a login is a tiny share of requests, so its latency matters far less than
# the CPU it takes from everything else. For the same reason workers run at a lower priority.

const JOB_LOCK = Threads.SpinLock()
const JOBS = Req[]
const JOB_EFD = Ref{Cint}(-1)
const BCRYPT_WAIT_MS = Ref(40)
const BCRYPT_COST = 10

function bcrypt_submit(r::Req)
    lock(JOB_LOCK)
    push!(JOBS, r)
    unlock(JOB_LOCK)
    eventfd_signal(JOB_EFD[])
    nothing
end

function njobs()
    lock(JOB_LOCK)
    n = length(JOBS)
    unlock(JOB_LOCK)
    n
end

# blocks for the first job, then gathers up to four. Each submit adds one count; a worker may take jobs whose
# counts another worker consumed, so a wake-up can find the queue empty (and is just a spurious wake-up).
function bcrypt_take!(out::Vector{Req})
    empty!(out)
    eventfd_wait(JOB_EFD[])
    njobs() == 0 && return out
    waited = 0
    while njobs() < 4 && waited < BCRYPT_WAIT_MS[]
        @ccall gc_safe = true usleep(2000::Cuint)::Cint
        waited += 2
    end
    lock(JOB_LOCK)
    while length(out) < 4 && !isempty(JOBS)
        push!(out, popfirst!(JOBS))
    end
    unlock(JOB_LOCK)
    out
end

function getrandom!(v::Vector{UInt8})
    n = GC.@preserve v ccall(:getrandom, Cssize_t, (Ptr{UInt8}, Csize_t, Cuint), pointer(v), length(v), 0)
    n == length(v) || error("getrandom failed")
    v
end

# loads request r into lane job jb; false if its stored hash is unusable
function bcrypt_load!(jb::BcryptJob, r::Req)
    a = r.arena
    n = min(r.pw_len, 72)
    copyto!(jb.pw, 1, a.data, r.pw_off + 1, n)
    jb.pwlen = n
    if r.flag
        # new hash: "$2b$10$" + fresh 16-byte salt
        getrandom!(jb.saltb)
        b = Buf(jb.setting, 0)
        wr!(b, "\$2b\$10\$")
        bcrypt_b64!(b, jb.saltb, 16)
        jb.cost = BCRYPT_COST
        return true
    end
    r.hash_len == 60 || return false
    copyto!(jb.setting, 1, a.data, r.hash_off + 1, 29)
    jb.cost = bcrypt_parse!(jb.saltb, jb.setting, 0, 29)
    jb.cost > 0
end

function bcrypt_finish!(jb::BcryptJob, r::Req)
    a = r.arena
    o = jb.out
    if r.flag
        r.hash_off = a.len
        wr!(a, o.data, 0, o.len)
        r.hash_len = o.len
        r.bcrypt_ok = true
    else
        diff = 0x00
        for k in 30:60
            diff |= o.data[k] ⊻ a.data[r.hash_off+k]
        end
        r.bcrypt_ok = diff == 0x00
    end
end

function bcrypt_post(r::Req)
    lp = LOOPS[r.loopid]
    lock(lp.done_lock)
    push!(lp.done, r)
    unlock(lp.done_lock)
    eventfd_signal(lp.efd)
end

function bcrypt_worker(nice::Int)
    nice != 0 && set_thread_nice(nice)
    z = BcryptLanes()
    jobs = [BcryptJob() for _ in 1:4]
    lane = BcryptJob[]
    group = Req[]
    taken = Req[]
    while true
        bcrypt_take!(taken)
        isempty(taken) && continue
        try
            # unusable hashes fail at once; the rest run in groups of equal cost
            pending = Req[]
            for r in taken
                r.bcrypt_ok = false
                if bcrypt_load!(jobs[length(pending)+1], r)
                    push!(pending, r)
                else
                    bcrypt_post(r)
                end
            end
            used = falses(length(pending))
            for i in eachindex(pending)
                used[i] && continue
                empty!(lane)
                empty!(group)
                for k in i:length(pending)
                    if !used[k] && jobs[k].cost == jobs[i].cost
                        used[k] = true
                        push!(lane, jobs[k])
                        push!(group, pending[k])
                    end
                end
                bcrypt_lanes!(z, lane, length(lane))
                for k in eachindex(group)
                    bcrypt_finish!(lane[k], group[k])
                    bcrypt_post(group[k])
                end
            end
        catch e
            @error "bcrypt" exception = (e, catch_backtrace())
            for r in taken
                r.hash_len = -1
                bcrypt_post(r)
            end
        end
    end
end
