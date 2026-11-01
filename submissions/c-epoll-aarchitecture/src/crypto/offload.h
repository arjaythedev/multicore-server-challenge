#ifndef CRYPTO_OFFLOAD_H
#define CRYPTO_OFFLOAD_H

#include "core/loop.h"

/* thread pool for bcrypt and pg result rendering: work runs on a pool thread,
 * resume on the submitting worker's event loop, so handler state stays
 * single-threaded; never joined */

typedef void (*crypto_work_fn)(void *arg);
typedef void (*crypto_resume_fn)(void *arg);

/* before any worker loop; pool + one completion eventfd per worker */
void crypto_init(int threads, int workers);

/* register worker_id's completion eventfd on its loop */
void crypto_bind(int worker_id, loop *l);

/* queue one job; arg owned by the job until resume(arg) returns */
void crypto_submit(int worker_id, crypto_work_fn work, crypto_resume_fn resume,
                   void *arg);

/* no pool work: resume(arg) runs on the worker's loop as-is (thread hop) */
void crypto_post(int worker_id, crypto_resume_fn resume, void *arg);

#endif
