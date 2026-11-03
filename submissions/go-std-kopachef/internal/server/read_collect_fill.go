package server

import "time"

// Experimental collector: after the normal window, keep filling only while
// waiting for a worker. A ready worker is checked before receiving more calls.
func (q *readQueue) collectWhileWaiting() {
	defer q.workers.Done()
	timer := time.NewTimer(time.Hour)
	timer.Stop()
	defer timer.Stop()
collect:
	for {
		batch := make([]*queuedRead, 0, q.batchSize)
		select {
		case first := <-q.pending:
			batch = append(batch, first)
		case <-q.ctx.Done():
			return
		}
		if q.batchWait > 0 {
			timer.Reset(q.batchWait)
		}
	drain:
		for len(batch) < q.batchSize {
			if q.batchWait > 0 {
				select {
				case call := <-q.pending:
					batch = append(batch, call)
				case <-timer.C:
					break drain
				case <-q.ctx.Done():
					return
				}
				continue
			}
			select {
			case call := <-q.pending:
				batch = append(batch, call)
			default:
				break drain
			}
		}
		timer.Stop()
		{
			for len(batch) < q.batchSize {
				// Dispatch immediately if a worker is ready. Otherwise use
				// the existing worker wait to fill this same bounded batch.
				select {
				case q.work <- batch:
					continue collect
				default:
				}
				select {
				case q.work <- batch:
					continue collect
				case call := <-q.pending:
					batch = append(batch, call)
				case <-q.ctx.Done():
					return
				}
			}
		}
		select {
		case q.work <- batch:
		case <-q.ctx.Done():
			return
		}
	}
}
