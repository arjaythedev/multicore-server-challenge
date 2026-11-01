package main

func readCount(n *int64) func(*pgRows) error {
	return func(rows *pgRows) error {
		if rows.Next() {
			*n = rows.i64(0)
		}
		return rows.err
	}
}

// finishList closes a list response whose articles are already in op.Resp.
func finishList(s *opState, count int64) {
	op := s.op
	op.Resp = append(op.Resp, `],"articlesCount":`...)
	op.Resp = appendInt(op.Resp, count)
	op.Resp = append(op.Resp, '}')
	s.done()
}
