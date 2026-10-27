package main

import (
	"github.com/jackc/pgx/v5/pgconn"
)

func prepGetComments(t *reqCtx) nextStep {
	if !validUTF8Text(t.req.slugParam) {
		return finishWith(t, 404, msgArticle404)
	}
	qp := &t.plan
	qp.sqlID = opComments
	qp.bindInt8(qp.viewerID)
	qp.bindText(t.req.slugParam)
	return stepRunSQL
}

func prepCreateComment(t *reqCtx) nextStep {
	var env bodyEnvelope
	if err := decodeEnvelope(&t.req, "comment", &env); err != nil {
		return finishWith(t, 422, msgMalformedBody)
	}
	bodyVal, errB := env.requiredStr(env.body, "body")
	if errB != nil || !noNullByte(bodyVal) {
		return finishWith(t, 422, msgCmtRequired)
	}
	if !validUTF8Text(t.req.slugParam) {
		return finishWith(t, 404, msgArticle404)
	}
	qp := &t.plan
	qp.sqlID = opCommentCreate
	qp.bindText(t.req.slugParam)
	qp.bindInt8(qp.viewerID)
	qp.bindText(bodyVal)
	return stepRunSQL
}

func prepDeleteComment(t *reqCtx) nextStep {
	cid, valid := parsePositiveInt(t.req.commentIDParam)
	if !valid || !validUTF8Text(t.req.slugParam) {
		return finishWith(t, 404, msgComment404)
	}
	qp := &t.plan
	qp.sqlID = opCommentDelete
	qp.bindInt8(cid)
	qp.bindText(t.req.slugParam)
	qp.bindInt8(qp.viewerID)
	return stepRunSQL
}

func decodeCommentRows(t *reqCtx, rr *pgconn.ResultReader) rowOutcome {
	qp := &t.plan
	qp.jsonBuf = append(qp.jsonBuf, `{"comments":[`...)
	var articleFound bool
	written := 0
	for rr.NextRow() {
		articleFound = true
		cols := rr.Values()
		if cols[0] == nil {
			continue
		}
		if written > 0 {
			qp.jsonBuf = append(qp.jsonBuf, ',')
		}
		qp.jsonBuf = writeCommentObject(qp.jsonBuf, cols, cols[7])
		written++
	}
	qp.jsonBuf = append(qp.jsonBuf, "]}"...)
	if !articleFound {
		return errOutcome(404, msgArticle404)
	}
	return okOutcome(200)
}

func decodeCreatedCommentRow(t *reqCtx, rr *pgconn.ResultReader) rowOutcome {
	if !rr.NextRow() {
		return errOutcome(404, msgArticle404)
	}
	qp := &t.plan
	qp.jsonBuf = append(qp.jsonBuf, `{"comment":`...)
	qp.jsonBuf = writeCommentObject(qp.jsonBuf, rr.Values(), nil)
	qp.jsonBuf = append(qp.jsonBuf, '}')
	return okOutcome(201)
}

func (s *pgSession) decodeBatchComments(batch []*reqCtx, rr *pgconn.ResultReader) error {
	count := len(batch)
	for _, t := range batch {
		qp := &t.plan
		qp.rowsSeen = 0
		qp.parentFound = false
		qp.jsonBuf = append(qp.jsonBuf[:0], `{"comments":[`...)
	}
	for rr.NextRow() {
		cols := rr.Values()
		slot := int(decodePGInt8(cols[8])) - 1
		if uint(slot) < uint(count) {
			t := batch[slot]
			qp := &t.plan
			qp.parentFound = true
			if cols[0] != nil {
				if qp.rowsSeen > 0 {
					qp.jsonBuf = append(qp.jsonBuf, ',')
				}
				qp.jsonBuf = writeCommentObject(qp.jsonBuf, cols, cols[7])
				qp.rowsSeen++
			}
		}
	}
	if _, err := rr.Close(); err != nil {
		return err
	}
	for _, t := range batch {
		qp := &t.plan
		if !qp.parentFound {
			finishWith(t, 404, msgArticle404)
		} else {
			qp.jsonBuf = append(qp.jsonBuf, "]}"...)
			t.finishJSON(200)
		}
	}
	s.engine.srv.completeAsyncBatch(batch)
	return nil
}

func (s *pgSession) decodeBatchCommentWrite(batch []*reqCtx, rr *pgconn.ResultReader) error {
	count := len(batch)
	for _, t := range batch {
		t.plan.rowsSeen = 0
		t.plan.nextAction = stepRespond
	}
	for rr.NextRow() {
		cols := rr.Values()
		slot := int(decodePGInt8(cols[7])) - 1
		if uint(slot) < uint(count) {
			t := batch[slot]
			qp := &t.plan
			qp.rowsSeen = 1
			qp.jsonBuf = append(qp.jsonBuf[:0], `{"comment":`...)
			qp.jsonBuf = writeCommentObject(qp.jsonBuf, cols, nil)
			qp.jsonBuf = append(qp.jsonBuf, '}')
		}
	}
	if _, err := rr.Close(); err != nil {
		return err
	}
	for _, t := range batch {
		if t.plan.rowsSeen == 0 {
			finishWith(t, 404, msgArticle404)
		} else {
			t.finishJSON(201)
		}
	}
	return nil
}

func writeCommentObject(dst []byte, cols [][]byte, following []byte) []byte {
	dst = append(dst, `{"id":`...)
	dst = writePGInt8(dst, cols[0])
	dst = writeTimestamps(dst, cols[2], cols[3])
	dst = append(dst, `,"body":`...)
	dst = writeJSONStr(dst, cols[1])
	dst = append(dst, `,"author":`...)
	dst = writeProfileObject(dst, cols[4], cols[5], cols[6], following)
	return append(dst, '}')
}
