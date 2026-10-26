package main

import (
	"strconv"

	"github.com/jackc/pgx/v5/pgconn"
)

func prepGetTags(t *reqCtx) nextStep {
	t.plan.sqlID = opTags
	return stepRunSQL
}

func prepGetArticle(t *reqCtx) nextStep {
	if !validUTF8Text(t.req.slugParam) {
		return finishWith(t, 404, msgArticle404)
	}
	qp := &t.plan
	qp.sqlID = opArticle
	qp.bindInt8(qp.viewerID)
	qp.bindText(t.req.slugParam)
	return stepRunSQL
}

func prepFavoriteArticle(t *reqCtx) nextStep {
	if !validUTF8Text(t.req.slugParam) {
		return finishWith(t, 404, msgArticle404)
	}
	qp := &t.plan
	qp.sqlID = opFavorite
	qp.bindInt8(qp.viewerID)
	qp.bindText(t.req.slugParam)
	return stepRunSQL
}

func prepUnfavoriteArticle(t *reqCtx) nextStep {
	if !validUTF8Text(t.req.slugParam) {
		return finishWith(t, 404, msgArticle404)
	}
	qp := &t.plan
	qp.sqlID = opUnfavorite
	qp.bindInt8(qp.viewerID)
	qp.bindText(t.req.slugParam)
	return stepRunSQL
}

func prepListArticles(t *reqCtx) nextStep {
	lim, off, ok := parsePageParams(&t.req)
	if !ok {
		return finishWith(t, 422, msgBadPagination)
	}
	qp := &t.plan
	uq := &t.req.query
	qp.sqlID = opListAll
	var filterVal string
	if tag := uq.getOrEmpty("tag"); tag != "" {
		qp.sqlID = opListTag
		filterVal = tag
	} else if author := uq.getOrEmpty("author"); author != "" {
		qp.sqlID = opListAuthor
		filterVal = author
	} else if fav := uq.getOrEmpty("favorited"); fav != "" {
		qp.sqlID = opListFav
		filterVal = fav
	}
	if filterVal != "" && !validUTF8Text(filterVal) {
		qp.jsonBuf = append(qp.jsonBuf[:0], `{"articles":[],"articlesCount":0}`...)
		return t.finishJSON(200)
	}
	qp.bindInt8(qp.viewerID)
	qp.bindInt8(lim)
	qp.bindInt8(off)
	if filterVal != "" {
		qp.bindText(filterVal)
	}
	return stepRunSQL
}

func prepFeedArticles(t *reqCtx) nextStep {
	lim, off, ok := parsePageParams(&t.req)
	if !ok {
		return finishWith(t, 422, msgBadPagination)
	}
	qp := &t.plan
	qp.sqlID = opListFeed
	qp.bindInt8(qp.viewerID)
	qp.bindInt8(lim)
	qp.bindInt8(off)
	return stepRunSQL
}

func prepCreateArticle(t *reqCtx) nextStep {
	var env bodyEnvelope
	if err := decodeEnvelope(&t.req, "article", &env); err != nil {
		return finishWith(t, 422, msgMalformedBody)
	}
	titleVal, errT := env.requiredStr(env.title, "title")
	descVal, errD := env.requiredStr(env.description, "description")
	bodyVal, errB := env.requiredStr(env.body, "body")
	if errT != nil || errD != nil || errB != nil ||
		!noNullByte(titleVal) || !noNullByte(descVal) || !noNullByte(bodyVal) {
		return finishWith(t, 422, msgArtRequired)
	}
	tags, tagErr := env.extractTags()
	if tagErr != nil {
		return finishWith(t, 422, tagErr)
	}
	for _, item := range tags {
		if !noNullByte(item) {
			return finishWith(t, 422, msgBadTagList)
		}
	}
	qp := &t.plan
	qp.sqlID = opArticleCreate
	qp.bindInt8(qp.viewerID)
	qp.bindText(titleVal)
	qp.bindText(descVal)
	qp.bindText(bodyVal)
	qp.arrayBuf = encodePGTextArray(qp.arrayBuf[:0], tags)
	qp.bindRawBytes(qp.arrayBuf)
	return stepRunSQL
}

func prepUpdateArticle(t *reqCtx) nextStep {
	var env bodyEnvelope
	if err := decodeEnvelope(&t.req, "article", &env); err != nil {
		return finishWith(t, 422, msgMalformedBody)
	}
	titleVal, hasTitle, errT := env.optionalStr(env.title, "title", true)
	descVal, hasDesc, errD := env.optionalStr(env.description, "description", true)
	bodyVal, hasBody, errB := env.optionalStr(env.body, "body", true)
	if errT != nil || errD != nil || errB != nil ||
		!noNullByte(titleVal) || !noNullByte(descVal) || !noNullByte(bodyVal) {
		return finishWith(t, 422, msgBadArtUpdate)
	}
	if !validUTF8Text(t.req.slugParam) {
		return finishWith(t, 404, msgArticle404)
	}
	qp := &t.plan
	qp.sqlID = opArticleUpdate
	qp.bindText(t.req.slugParam)
	qp.bindNullableText(titleVal, hasTitle)
	qp.bindNullableText(descVal, hasDesc)
	qp.bindNullableText(bodyVal, hasBody)
	qp.bindInt8(qp.viewerID)
	return stepRunSQL
}

func prepDeleteArticle(t *reqCtx) nextStep {
	if !validUTF8Text(t.req.slugParam) {
		return finishWith(t, 404, msgArticle404)
	}
	qp := &t.plan
	qp.sqlID = opArticleDelete
	qp.bindText(t.req.slugParam)
	qp.bindInt8(qp.viewerID)
	return stepRunSQL
}

func decodeTagsRow(t *reqCtx, rr *pgconn.ResultReader) rowOutcome {
	qp := &t.plan
	qp.jsonBuf = append(qp.jsonBuf, `{"tags":`...)
	if rr.NextRow() {
		qp.jsonBuf = writePGTextArray(qp.jsonBuf, rr.Values()[0])
	} else {
		qp.jsonBuf = append(qp.jsonBuf, `[]`...)
	}
	qp.jsonBuf = append(qp.jsonBuf, '}')
	return okOutcome(200)
}

func decodeArticleListRows(t *reqCtx, rr *pgconn.ResultReader) rowOutcome {
	qp := &t.plan
	qp.jsonBuf = append(qp.jsonBuf, `{"articles":[`...)
	var total int64
	var seenTotal bool
	written := 0
	for rr.NextRow() {
		cols := rr.Values()
		if !seenTotal {
			total = decodePGInt8(cols[0])
			seenTotal = true
		}
		if cols[1] == nil {
			continue
		}
		if written > 0 {
			qp.jsonBuf = append(qp.jsonBuf, ',')
		}
		qp.jsonBuf = writeArticleObject(qp.jsonBuf, cols, 1, false)
		written++
	}
	qp.jsonBuf = append(qp.jsonBuf, `],"articlesCount":`...)
	qp.jsonBuf = strconv.AppendInt(qp.jsonBuf, total, 10)
	qp.jsonBuf = append(qp.jsonBuf, '}')
	return okOutcome(200)
}

func decodeArticleRow(t *reqCtx, rr *pgconn.ResultReader, status int) rowOutcome {
	if !rr.NextRow() {
		if status == 201 {
			return errOutcome(500, msgServerError)
		}
		return errOutcome(404, msgArticle404)
	}
	qp := &t.plan
	qp.jsonBuf = append(qp.jsonBuf, `{"article":`...)
	qp.jsonBuf = writeArticleObject(qp.jsonBuf, rr.Values(), 0, true)
	qp.jsonBuf = append(qp.jsonBuf, '}')
	return okOutcome(status)
}

func decodeUpdateArticleRow(t *reqCtx, rr *pgconn.ResultReader) rowOutcome {
	qp := &t.plan
	res := errOutcome(404, msgArticle404)
	for rr.NextRow() {
		cols := rr.Values()
		if decodePGInt8(cols[0]) != qp.viewerID {
			res = errOutcome(403, msgForbidden)
		} else if cols[1] != nil {
			qp.jsonBuf = append(qp.jsonBuf[:0], `{"article":`...)
			qp.jsonBuf = writeArticleObject(qp.jsonBuf, cols, 1, true)
			qp.jsonBuf = append(qp.jsonBuf, '}')
			res = okOutcome(200)
		}
	}
	return res
}

func decodeDeleteRow(t *reqCtx, rr *pgconn.ResultReader, notFoundMsg []byte) rowOutcome {
	res := errOutcome(404, notFoundMsg)
	for rr.NextRow() {
		if decodePGInt8(rr.Values()[0]) != t.plan.viewerID {
			res = errOutcome(403, msgForbidden)
		} else {
			res = okOutcome(204)
		}
	}
	return res
}

func (s *pgSession) decodeBatchTags(batch []*reqCtx, rr *pgconn.ResultReader) error {
	first := batch[0]
	qp0 := &first.plan
	qp0.jsonBuf = append(qp0.jsonBuf[:0], `{"tags":`...)
	if rr.NextRow() {
		qp0.jsonBuf = writePGTextArray(qp0.jsonBuf, rr.Values()[0])
	} else {
		qp0.jsonBuf = append(qp0.jsonBuf, `[]`...)
	}
	qp0.jsonBuf = append(qp0.jsonBuf, '}')
	if _, err := rr.Close(); err != nil {
		return err
	}
	first.finishJSON(200)
	for i := 1; i < len(batch); i++ {
		ti := batch[i]
		ti.plan.jsonBuf = append(ti.plan.jsonBuf[:0], qp0.jsonBuf...)
		ti.finishJSON(200)
	}
	s.engine.srv.completeAsyncBatch(batch)
	return nil
}

func (s *pgSession) decodeBatchArticle(batch []*reqCtx, rr *pgconn.ResultReader) error {
	count := len(batch)
	for _, t := range batch {
		t.plan.rowsSeen = 0
	}
	for rr.NextRow() {
		cols := rr.Values()
		slot := int(decodePGInt8(cols[13])) - 1
		if uint(slot) < uint(count) {
			t := batch[slot]
			qp := &t.plan
			qp.rowsSeen = 1
			qp.jsonBuf = append(qp.jsonBuf[:0], `{"article":`...)
			qp.jsonBuf = writeArticleObject(qp.jsonBuf, cols, 0, true)
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
			t.finishJSON(200)
		}
	}
	s.engine.srv.completeAsyncBatch(batch)
	return nil
}

func (s *pgSession) decodeBatchArticleList(batch []*reqCtx, rr *pgconn.ResultReader) error {
	count := len(batch)
	for _, t := range batch {
		qp := &t.plan
		qp.rowsSeen = 0
		qp.parentFound = false
		qp.totalRows = 0
		qp.jsonBuf = append(qp.jsonBuf[:0], `{"articles":[`...)
	}
	for rr.NextRow() {
		cols := rr.Values()
		slot := int(decodePGInt8(cols[13])) - 1
		if uint(slot) < uint(count) {
			t := batch[slot]
			qp := &t.plan
			if !qp.parentFound {
				qp.parentFound = true
				qp.totalRows = decodePGInt8(cols[0])
			}
			if cols[1] != nil {
				if qp.rowsSeen > 0 {
					qp.jsonBuf = append(qp.jsonBuf, ',')
				}
				qp.jsonBuf = writeArticleObject(qp.jsonBuf, cols, 1, false)
				qp.rowsSeen++
			}
		}
	}
	if _, err := rr.Close(); err != nil {
		return err
	}
	for _, t := range batch {
		qp := &t.plan
		qp.jsonBuf = append(qp.jsonBuf, `],"articlesCount":`...)
		qp.jsonBuf = strconv.AppendInt(qp.jsonBuf, qp.totalRows, 10)
		qp.jsonBuf = append(qp.jsonBuf, '}')
		t.finishJSON(200)
	}
	s.engine.srv.completeAsyncBatch(batch)
	return nil
}

func (s *pgSession) decodeBatchFavoriteWrite(batch []*reqCtx, rr *pgconn.ResultReader) error {
	count := len(batch)
	for _, t := range batch {
		t.plan.rowsSeen = 0
		t.plan.nextAction = stepRespond
	}
	for rr.NextRow() {
		cols := rr.Values()
		slot := int(decodePGInt8(cols[13])) - 1
		if uint(slot) < uint(count) {
			t := batch[slot]
			qp := &t.plan
			qp.rowsSeen = 1
			qp.jsonBuf = append(qp.jsonBuf[:0], `{"article":`...)
			qp.jsonBuf = writeArticleObject(qp.jsonBuf, cols, 0, true)
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
			t.finishJSON(200)
		}
	}
	return nil
}

func writeArticleObject(dst []byte, cols [][]byte, offset int, includeBody bool) []byte {
	idx := offset
	dst = append(dst, `{"slug":`...)
	dst = writeJSONStr(dst, cols[idx])
	dst = append(dst, `,"title":`...)
	dst = writeJSONStr(dst, cols[idx+1])
	dst = append(dst, `,"description":`...)
	dst = writeJSONStr(dst, cols[idx+2])
	idx += 3
	if includeBody {
		dst = append(dst, `,"body":`...)
		dst = writeJSONStr(dst, cols[idx])
		idx++
	}
	createdRaw, updatedRaw, tagsRaw, favCountRaw, favFlagRaw := cols[idx], cols[idx+1], cols[idx+2], cols[idx+3], cols[idx+4]
	dst = append(dst, `,"tagList":`...)
	dst = writePGTextArray(dst, tagsRaw)
	dst = writeTimestamps(dst, createdRaw, updatedRaw)
	dst = append(dst, `,"favorited":`...)
	dst = writeJSONBool(dst, favFlagRaw)
	dst = append(dst, `,"favoritesCount":`...)
	dst = writePGInt8(dst, favCountRaw)
	dst = append(dst, `,"author":`...)
	dst = writeProfileObject(dst, cols[idx+5], cols[idx+6], cols[idx+7], cols[idx+8])
	return append(dst, '}')
}
