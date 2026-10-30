# bcq.s: the bcrypt thread(s). Workers push jobs (J_BCKIND 1 verify / 2 hash, J_BC holds the bcrypt.s job)
# onto one lock-free stack and wake a bcrypt thread with a futex. A bcrypt thread moves the stack into its own
# FIFO, runs it oldest first in batches of up to BCQ_LANES same-kind jobs (interleaved lanes), then pushes each job
# onto its worker's completion stack and signals the worker's eventfd; the worker resumes the job there.
# A job that waited more than BCRYPT_SHED_MS before starting is shed (J_BUSY = 1, answered 503), like Rust.
# Thread 0 takes every submitted job. Threads 1.. are helpers: when BCQ_LANES or more jobs are still queued behind
# the batch thread 0 is about to run, it hands the oldest BCQ_LANES of them to an idle helper, so a backlog runs
# on two cores while an ordinary load leaves the helpers asleep (no fragmented batches, no stolen core).
.include "defs.inc"
.include "app.inc"

.equ BCRYPT_SHED_MS, 8000
.equ BCQ_LANES, 6                    # jobs per batch: one engine run (bcrypt.s splits n > 6)

.data
# BCRYPT_BATCH_MS (main.s): with fewer than BCQ_LANES jobs pending, wait for more until the oldest has waited this
# long, so batches run on more lanes (a 6-lane run costs a hash about 0.8x what a 4-lane run does). 0 = run at once.
.globl g_bc_fill_ms
g_bc_fill_ms: .quad 150

.bss
.balign 64
bc_stack:  .quad 0                       # MPSC stack of jobs (J_NEXT links)
.balign 64
bc_futex:  .long 0                       # bumped on every push
.balign 64
bc_help:   .quad 0                       # jobs handed to the helpers (newest first, J_NEXT links; thread 0 sets it)
bc_hfutex: .long 0                       # bumped on every hand-off

.text

# bcq_submit(job): hand a job to the bcrypt threads (worker side). The job continues in J_CONT(job, 0, 0).
.globl bcq_submit
bcq_submit:
    push rbx
    mov rbx, rdi
    mov [rbx + J_WORKER], r15
    call rt_mono_ms
    mov [rbx + J_T0], rax
    mov qword ptr [rbx + J_BUSY], 0
    mov rax, [rip + bc_stack]
1:  mov [rbx + J_NEXT], rax
    lock cmpxchg [rip + bc_stack], rbx   # if bc_stack == rax: bc_stack = rbx, else rax = bc_stack
    jnz 1b
    lock inc dword ptr [rip + bc_futex]
    lea rdi, [rip + bc_futex]
    mov esi, FUTEX_WAKE_PRIVATE
    mov edx, 1
    SYS SYS_futex
    pop rbx
    ret

# bcq_thread(index): never returns (index 0 = the main thread, the rest are helpers). Pending jobs form one FIFO (oldest first). Each batch takes the oldest job's
# kind and up to BCQ_LANES jobs of that kind from anywhere in the FIFO (the rest keep their order), so a mix of
# logins and sign-ups still fills the lanes; new arrivals are appended before every batch.
.equ BT_JOBS, BCJ_SIZE * BCRYPT_LANES           # app jobs of the lanes (8 * BCRYPT_LANES)
.equ BT_TAIL, BT_JOBS + 8 * BCRYPT_LANES        # FIFO tail (valid when r12 != 0)
.equ BT_KTAIL, BT_TAIL + 8                      # scan: last job kept in the FIFO (0 = none yet)
.equ BT_NEXT, BT_KTAIL + 8                      # scan: the job after the current one
.equ BT_TS, BT_NEXT + 8                         # fill wait: futex timeout {sec, nsec}
.equ BT_SRC, BT_TS + 16                         # &bc_stack (thread 0) or &bc_help (helpers)
.equ BT_FUT, BT_SRC + 8                         # &bc_futex or &bc_hfutex
.equ BT_IDX, BT_FUT + 8                         # thread index
.equ BT_FRAME, BT_IDX + 8                       # 640: 16-byte aligned after 5 pushes
.globl bcq_thread
bcq_thread:
    push rbx
    push r12
    push r13
    push r14
    push rbp
    sub rsp, BT_FRAME
    # [rsp] = BCRYPT_LANES jobs for bcrypt.s, then [rsp + BT_JOBS] = the app jobs they belong to
    mov [rsp + BT_IDX], rdi
    lea rax, [rip + bc_stack]
    lea rcx, [rip + bc_futex]
    test rdi, rdi
    jz 1f
    lea rax, [rip + bc_help]
    lea rcx, [rip + bc_hfutex]
1:  mov [rsp + BT_SRC], rax
    mov [rsp + BT_FUT], rcx
    xor r12d, r12d                       # FIFO head (0 = empty)
.Lbt_wait:
    mov rcx, [rsp + BT_FUT]
    mov ebx, [rcx]
    mov rcx, [rsp + BT_SRC]
    xor eax, eax
    xchg rax, [rcx]
    test rax, rax
    jnz .Lbt_got
    test r12, r12
    jnz .Lbt_batch
    mov rdi, [rsp + BT_FUT]
    mov esi, FUTEX_WAIT_PRIVATE
    mov edx, ebx
    xor r10d, r10d
    SYS SYS_futex
    jmp .Lbt_wait
.Lbt_got:
    # the stack is newest first: reverse it (rcx = oldest new job, rdx = newest) and append it to the FIFO
    mov rdx, rax
    xor ecx, ecx
1:  mov rsi, [rax + J_NEXT]
    mov [rax + J_NEXT], rcx
    mov rcx, rax
    mov rax, rsi
    test rax, rax
    jnz 1b
    test r12, r12
    jnz 2f
    mov r12, rcx
    jmp 3f
2:  mov rax, [rsp + BT_TAIL]
    mov [rax + J_NEXT], rcx
3:  mov [rsp + BT_TAIL], rdx
.Lbt_batch:
    # fill wait: fewer than BCQ_LANES jobs pending and the oldest younger than g_bc_fill_ms -> sleep on the futex
    # (ebx still holds the value read before the stack was taken) until a push or the oldest's deadline.
    # Helpers never wait: a hand-off is already BCQ_LANES jobs.
    cmp qword ptr [rsp + BT_IDX], 0
    jne .Lbt_go
    mov rax, [rip + g_bc_fill_ms]
    test rax, rax
    jz .Lbt_go
    mov ecx, 1
    mov rdx, r12
1:  mov rdx, [rdx + J_NEXT]
    test rdx, rdx
    jz 2f
    inc ecx
    cmp ecx, BCQ_LANES
    jb 1b
    jmp .Lbt_go
2:  call rt_mono_ms
    sub rax, [r12 + J_T0]                # age of the oldest (ms)
    mov rcx, [rip + g_bc_fill_ms]
    sub rcx, rax
    jle .Lbt_go
    imul rcx, rcx, 1000000
    xor edx, edx
    mov rax, rcx
    mov ecx, 1000000000
    div rcx
    mov [rsp + BT_TS], rax
    mov [rsp + BT_TS + 8], rdx
    lea rdi, [rip + bc_futex]
    mov esi, FUTEX_WAIT_PRIVATE
    mov edx, ebx
    lea r10, [rsp + BT_TS]
    SYS SYS_futex
    jmp .Lbt_wait
.Lbt_go:
    mov r13, [r12 + J_BCKIND]
    xor r14d, r14d                       # lanes
    call rt_mono_ms
    mov rbp, rax                         # now (ms)
    mov rbx, r12                         # scan the FIFO, rebuilding it from the jobs not taken
    xor r12d, r12d
    mov qword ptr [rsp + BT_KTAIL], 0
.Lbt_scan:
    test rbx, rbx
    jz .Lbt_scanned
    cmp r14d, BCQ_LANES
    jae .Lbt_rest
    mov rax, [rbx + J_NEXT]
    mov [rsp + BT_NEXT], rax
    cmp [rbx + J_BCKIND], r13
    jne .Lbt_keep
    mov rax, rbp
    sub rax, [rbx + J_T0]
    cmp rax, BCRYPT_SHED_MS
    jle 4f
    mov qword ptr [rbx + J_BUSY], 1
    mov rdi, rbx
    call bcq_complete
    jmp .Lbt_next
4:  mov rax, r14
    shl rax, 6                           # * BCJ_SIZE
    lea rdi, [rsp + rax]
    lea rsi, [rbx + J_BC]
    mov edx, BCJ_SIZE
    call rt_memcpy
    mov [rsp + BT_JOBS + r14*8], rbx
    inc r14d
    jmp .Lbt_next
.Lbt_keep:
    mov qword ptr [rbx + J_NEXT], 0
    mov rax, [rsp + BT_KTAIL]
    test rax, rax
    jnz 5f
    mov r12, rbx
    jmp 6f
5:  mov [rax + J_NEXT], rbx
6:  mov [rsp + BT_KTAIL], rbx
.Lbt_next:
    mov rbx, [rsp + BT_NEXT]
    jmp .Lbt_scan
.Lbt_rest:
    # lanes full: the unscanned rest (rbx .. the old tail) follows the kept jobs unchanged
    mov rax, [rsp + BT_KTAIL]
    test rax, rax
    jnz 7f
    mov r12, rbx
    jmp .Lbt_run
7:  mov [rax + J_NEXT], rbx
    jmp .Lbt_run
.Lbt_scanned:
    mov rax, [rsp + BT_KTAIL]
    mov [rsp + BT_TAIL], rax
.Lbt_run:
    test r14d, r14d
    jz .Lbt_wait
    # hand-off (thread 0, helpers exist, none pending): BCQ_LANES or more jobs queued behind this batch -> detach
    # the oldest BCQ_LANES, reverse them into a newest-first list (a helper reverses it back) and wake a helper
    cmp qword ptr [rsp + BT_IDX], 0
    jne .Lbt_exec
    cmp qword ptr [rip + g_nbcrypt], 1
    jbe .Lbt_exec
    cmp qword ptr [rip + bc_help], 0
    jne .Lbt_exec
    mov rdx, r12
    mov ecx, 1
1:  test rdx, rdx
    jz .Lbt_exec
    cmp ecx, BCQ_LANES
    jae 2f
    mov rdx, [rdx + J_NEXT]
    inc ecx
    jmp 1b
2:  mov rsi, [rdx + J_NEXT]              # the rest stays queued (BT_TAIL is still its tail)
    mov qword ptr [rdx + J_NEXT], 0
    mov rax, r12
    mov r12, rsi
    xor ecx, ecx
3:  mov rsi, [rax + J_NEXT]
    mov [rax + J_NEXT], rcx
    mov rcx, rax
    mov rax, rsi
    test rax, rax
    jnz 3b
    mov [rip + bc_help], rcx
    lock inc dword ptr [rip + bc_hfutex]
    lea rdi, [rip + bc_hfutex]
    mov esi, FUTEX_WAKE_PRIVATE
    mov edx, 1
    SYS SYS_futex
.Lbt_exec:
    mov rdi, rsp
    mov esi, r14d
    cmp r13, 1
    jne 3f
    call bcrypt_verify_batch
    jmp 4f
3:  call bcrypt_hash_batch
4:  # copy results back and complete
    xor ebx, ebx
5:  cmp ebx, r14d
    jae .Lbt_wait
    mov rdi, [rsp + BT_JOBS + rbx*8]
    mov rax, rbx
    shl rax, 6
    mov rcx, [rsp + rax + BCJ_RESULT]
    mov [rdi + J_BC + BCJ_RESULT], rcx
    call bcq_complete
    inc ebx
    jmp 5b

# bcq_complete(job): push onto the owning worker's completion stack and signal its eventfd.
bcq_complete:
    push rbx
    sub rsp, 16
    mov rdx, [rdi + J_WORKER]
    mov rax, [rdx + W_DONE]
1:  mov [rdi + J_NEXT], rax
    lock cmpxchg [rdx + W_DONE], rdi
    jnz 1b
    mov qword ptr [rsp], 1
    mov rdi, [rdx + W_EVFD]
    mov rsi, rsp
    mov edx, 8
    SYS SYS_write
    add rsp, 16
    pop rbx
    ret

.section .note.GNU-stack,"",@progbits
