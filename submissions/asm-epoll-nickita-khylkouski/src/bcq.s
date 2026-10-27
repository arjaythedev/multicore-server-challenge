# bcq.s: the bcrypt thread(s). Workers push jobs (J_BCKIND 1 verify / 2 hash, J_BC holds the bcrypt.s job)
# onto one lock-free stack and wake a bcrypt thread with a futex. A bcrypt thread moves the stack into its own
# FIFO, runs it oldest first in batches of up to BCQ_LANES same-kind jobs (interleaved lanes), then pushes each job
# onto its worker's completion stack and signals the worker's eventfd; the worker resumes the job there.
# A job that waited more than BCRYPT_SHED_MS before starting is shed (J_BUSY = 1, answered 503), like Rust.
.include "defs.inc"
.include "app.inc"

.equ BCRYPT_SHED_MS, 8000
.equ BCQ_LANES, 6                    # jobs per batch: one engine run (bcrypt.s splits n > 6)

.bss
.balign 64
bc_stack:  .quad 0                       # MPSC stack of jobs (J_NEXT links)
.balign 64
bc_futex:  .long 0                       # bumped on every push

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

# bcq_thread(index): never returns. Pending jobs form one FIFO (oldest first). Each batch takes the oldest job's
# kind and up to BCQ_LANES jobs of that kind from anywhere in the FIFO (the rest keep their order), so a mix of
# logins and sign-ups still fills the lanes; new arrivals are appended before every batch.
.equ BT_JOBS, BCJ_SIZE * BCRYPT_LANES           # app jobs of the lanes (8 * BCRYPT_LANES)
.equ BT_TAIL, BT_JOBS + 8 * BCRYPT_LANES        # FIFO tail (valid when r12 != 0)
.equ BT_KTAIL, BT_TAIL + 8                      # scan: last job kept in the FIFO (0 = none yet)
.equ BT_NEXT, BT_KTAIL + 8                      # scan: the job after the current one
.equ BT_FRAME, BT_NEXT + 8 + 8                  # (+ 8: 16-byte alignment after 5 pushes)
.globl bcq_thread
bcq_thread:
    push rbx
    push r12
    push r13
    push r14
    push rbp
    sub rsp, BT_FRAME
    # [rsp] = BCRYPT_LANES jobs for bcrypt.s, then [rsp + BT_JOBS] = the app jobs they belong to
    xor r12d, r12d                       # FIFO head (0 = empty)
.Lbt_wait:
    mov ebx, [rip + bc_futex]
    xor eax, eax
    xchg rax, [rip + bc_stack]
    test rax, rax
    jnz .Lbt_got
    test r12, r12
    jnz .Lbt_batch
    lea rdi, [rip + bc_futex]
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
