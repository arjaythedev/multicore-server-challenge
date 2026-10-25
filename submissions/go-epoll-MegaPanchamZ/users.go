package main

import (
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

func prepCurrentUser(t *reqCtx) nextStep {
	qp := &t.plan
	qp.sqlID = opUserByID
	qp.bindInt8(qp.viewerID)
	return stepRunSQL
}

func prepGetProfile(t *reqCtx) nextStep {
	if !validUTF8Text(t.req.userParam) {
		return finishWith(t, 404, msgProfile404)
	}
	qp := &t.plan
	qp.sqlID = opProfile
	qp.bindInt8(qp.viewerID)
	qp.bindText(t.req.userParam)
	return stepRunSQL
}

func prepFollowUser(t *reqCtx) nextStep {
	if !validUTF8Text(t.req.userParam) {
		return finishWith(t, 404, msgProfile404)
	}
	qp := &t.plan
	qp.sqlID = opFollow
	qp.bindInt8(qp.viewerID)
	qp.bindText(t.req.userParam)
	return stepRunSQL
}

func prepUnfollowUser(t *reqCtx) nextStep {
	if !validUTF8Text(t.req.userParam) {
		return finishWith(t, 404, msgProfile404)
	}
	qp := &t.plan
	qp.sqlID = opUnfollow
	qp.bindInt8(qp.viewerID)
	qp.bindText(t.req.userParam)
	return stepRunSQL
}

func prepLogin(t *reqCtx) nextStep {
	var env bodyEnvelope
	if err := decodeEnvelope(&t.req, "user", &env); err != nil {
		return finishWith(t, 422, msgMalformedBody)
	}
	emailVal, errEmail := env.requiredStr(env.email, "email")
	passVal, errPass := env.requiredStr(env.password, "password")
	if errEmail != nil || errPass != nil {
		return finishWith(t, 422, msgLoginRequired)
	}
	if !validUTF8Text(emailVal) {
		return finishWith(t, 401, msgBadLogin)
	}
	qp := &t.plan
	qp.userForm.email = emailVal
	qp.userForm.password = passVal
	qp.userForm.hasEmail = true
	qp.userForm.hasPassword = true
	qp.sqlID = opUserByEmail
	qp.bindText(emailVal)
	return stepRunSQL
}

func prepRegister(t *reqCtx) nextStep {
	qp := &t.plan
	if qp.passHashed {
		qp.sqlID = opRegister
		qp.bindText(qp.userForm.username)
		qp.bindText(qp.userForm.email)
		qp.bindRawBytes(qp.hashedSlice())
		return stepRunSQL
	}
	var env bodyEnvelope
	if err := decodeEnvelope(&t.req, "user", &env); err != nil {
		return finishWith(t, 422, msgMalformedBody)
	}
	unameVal, errU := env.requiredStr(env.username, "username")
	emailVal, errE := env.requiredStr(env.email, "email")
	passVal, errP := env.requiredStr(env.password, "password")
	if errU != nil || errE != nil || errP != nil || !noNullByte(unameVal) || !noNullByte(emailVal) {
		return finishWith(t, 422, msgRegRequired)
	}
	if len(passVal) > 72 {
		return finishWith(t, 422, msgPassTooLong)
	}
	qp.userForm.username = unameVal
	qp.userForm.email = emailVal
	qp.userForm.password = passVal
	qp.userForm.hasUsername = true
	qp.userForm.hasEmail = true
	qp.userForm.hasPassword = true
	return stepHashPass
}

func prepUpdateUser(t *reqCtx) nextStep {
	qp := &t.plan
	if !qp.passHashed {
		var env bodyEnvelope
		if err := decodeEnvelope(&t.req, "user", &env); err != nil {
			return finishWith(t, 422, msgMalformedBody)
		}
		uf := &qp.userForm
		var e0, e1, e2, e3, e4 error
		uf.email, uf.hasEmail, e0 = env.optionalStr(env.email, "email", true)
		uf.username, uf.hasUsername, e1 = env.optionalStr(env.username, "username", true)
		uf.password, uf.hasPassword, e2 = env.optionalStr(env.password, "password", true)
		uf.bio, uf.hasBio, e3 = env.optionalStr(env.bio, "bio", false)
		uf.image, uf.hasImage, e4 = env.optionalStr(env.image, "image", false)
		if e0 != nil || e1 != nil || e2 != nil || e3 != nil || e4 != nil ||
			!noNullByte(uf.email) || !noNullByte(uf.username) || !noNullByte(uf.bio) || !noNullByte(uf.image) {
			return finishWith(t, 422, msgBadUserUpdate)
		}
		if uf.hasPassword {
			if len(uf.password) > 72 {
				return finishWith(t, 422, msgPassTooLong)
			}
			return stepHashPass
		}
	}
	qp.sqlID = opUserUpdate
	qp.bindInt8(qp.viewerID)
	qp.bindNullableText(qp.userForm.email, qp.userForm.hasEmail)
	qp.bindNullableText(qp.userForm.username, qp.userForm.hasUsername)
	qp.bindRawBytes(qp.hashedSlice())
	qp.bindNullableText(qp.userForm.bio, qp.userForm.hasBio)
	qp.bindNullableText(qp.userForm.image, qp.userForm.hasImage)
	return stepRunSQL
}

func decodeCurrentUserRow(t *reqCtx, rr *pgconn.ResultReader) rowOutcome {
	if !rr.NextRow() {
		return errOutcome(401, msgUnauthorized)
	}
	cols := rr.Values()
	qp := &t.plan
	qp.jsonBuf = writeUserObject(qp.jsonBuf, cols[0], cols[1], cols[2], cols[3], qp.rawToken)
	return okOutcome(200)
}

func decodeLoginRow(t *reqCtx, rr *pgconn.ResultReader) rowOutcome {
	if !rr.NextRow() {
		return errOutcome(401, msgBadLogin)
	}
	cols := rr.Values()
	qp := &t.plan
	qp.matchedUID = decodePGInt8(cols[0])
	qp.jsonBuf = writeUserPrefix(qp.jsonBuf, cols[1], cols[2], cols[3], cols[4])
	if len(cols[5]) <= len(qp.bcryptBuf) {
		qp.bcryptLen = copy(qp.bcryptBuf[:], cols[5])
	} else {
		qp.bcryptLen = 0
	}
	return rowOutcome{httpCode: 200, followup: stepCheckPass}
}

func finishLoginVerify(signer *tokenSigner, t *reqCtx, matched bool) {
	if !matched {
		finishWith(t, 401, msgBadLogin)
		return
	}
	qp := &t.plan
	qp.jsonBuf = signer.encodeToken(qp.jsonBuf, qp.matchedUID, time.Now())
	qp.jsonBuf = append(qp.jsonBuf, `"}}`...)
	t.finishJSON(200)
}

func decodeRegisterRow(s *pgSession, t *reqCtx, rr *pgconn.ResultReader) rowOutcome {
	if !rr.NextRow() {
		return errOutcome(422, msgDuplicateUser)
	}
	cols := rr.Values()
	qp := &t.plan
	qp.jsonBuf = writeUserPrefix(qp.jsonBuf, cols[1], cols[2], cols[3], cols[4])
	qp.jsonBuf = s.signer.encodeToken(qp.jsonBuf, decodePGInt8(cols[0]), time.Now())
	qp.jsonBuf = append(qp.jsonBuf, `"}}`...)
	return okOutcome(201)
}

func decodeUpdateUserRow(t *reqCtx, rr *pgconn.ResultReader) rowOutcome {
	qp := &t.plan
	var hasConflict, hasUser bool
	for rr.NextRow() {
		cols := rr.Values()
		hasConflict = len(cols[0]) == 1 && cols[0][0] != 0
		if cols[1] != nil {
			qp.jsonBuf = writeUserObject(qp.jsonBuf[:0], cols[1], cols[2], cols[3], cols[4], qp.rawToken)
			hasUser = true
		}
	}
	if hasConflict {
		return errOutcome(422, msgDuplicateUser)
	}
	if !hasUser {
		return errOutcome(401, msgUnauthorized)
	}
	return okOutcome(200)
}

func decodeProfileRow(t *reqCtx, rr *pgconn.ResultReader) rowOutcome {
	if !rr.NextRow() {
		return errOutcome(404, msgProfile404)
	}
	cols := rr.Values()
	qp := &t.plan
	qp.jsonBuf = append(qp.jsonBuf, `{"profile":`...)
	qp.jsonBuf = writeProfileObject(qp.jsonBuf, cols[0], cols[1], cols[2], cols[3])
	qp.jsonBuf = append(qp.jsonBuf, '}')
	return okOutcome(200)
}

func decodeFollowRow(t *reqCtx, rr *pgconn.ResultReader, following bool) rowOutcome {
	if !rr.NextRow() {
		return errOutcome(404, msgProfile404)
	}
	cols := rr.Values()
	flag := pgBoolFalse
	if following {
		flag = pgBoolTrue
	}
	qp := &t.plan
	qp.jsonBuf = append(qp.jsonBuf, `{"profile":`...)
	qp.jsonBuf = writeProfileObject(qp.jsonBuf, cols[0], cols[1], cols[2], flag)
	qp.jsonBuf = append(qp.jsonBuf, '}')
	return okOutcome(200)
}

func (s *pgSession) decodeBatchUserByID(batch []*reqCtx, rr *pgconn.ResultReader) error {
	count := len(batch)
	for _, t := range batch {
		t.plan.rowsSeen = 0
	}
	for rr.NextRow() {
		cols := rr.Values()
		slot := int(decodePGInt8(cols[4])) - 1
		if uint(slot) < uint(count) {
			t := batch[slot]
			qp := &t.plan
			qp.rowsSeen = 1
			qp.jsonBuf = writeUserObject(qp.jsonBuf[:0], cols[0], cols[1], cols[2], cols[3], qp.rawToken)
		}
	}
	if _, err := rr.Close(); err != nil {
		return err
	}
	for _, t := range batch {
		if t.plan.rowsSeen == 0 {
			finishWith(t, 401, msgUnauthorized)
		} else {
			t.finishJSON(200)
		}
	}
	s.engine.srv.completeAsyncBatch(batch)
	return nil
}

func (s *pgSession) decodeBatchUserByEmail(batch []*reqCtx, rr *pgconn.ResultReader) error {
	count := len(batch)
	for _, t := range batch {
		t.plan.rowsSeen = 0
	}
	for rr.NextRow() {
		cols := rr.Values()
		slot := int(decodePGInt8(cols[6])) - 1
		if uint(slot) < uint(count) {
			t := batch[slot]
			qp := &t.plan
			qp.rowsSeen = 1
			qp.matchedUID = decodePGInt8(cols[0])
			qp.jsonBuf = writeUserPrefix(qp.jsonBuf[:0], cols[1], cols[2], cols[3], cols[4])
			if len(cols[5]) <= len(qp.bcryptBuf) {
				qp.bcryptLen = copy(qp.bcryptBuf[:], cols[5])
			} else {
				qp.bcryptLen = 0
			}
		}
	}
	if _, err := rr.Close(); err != nil {
		return err
	}
	for _, t := range batch {
		if t.plan.rowsSeen == 0 {
			finishWith(t, 401, msgBadLogin)
			s.engine.srv.completeAsync(t)
		} else {
			s.engine.submitPasswordTask(t)
		}
	}
	return nil
}

func (s *pgSession) decodeBatchProfile(batch []*reqCtx, rr *pgconn.ResultReader) error {
	count := len(batch)
	for _, t := range batch {
		t.plan.rowsSeen = 0
	}
	for rr.NextRow() {
		cols := rr.Values()
		slot := int(decodePGInt8(cols[4])) - 1
		if uint(slot) < uint(count) {
			t := batch[slot]
			qp := &t.plan
			qp.rowsSeen = 1
			qp.jsonBuf = append(qp.jsonBuf[:0], `{"profile":`...)
			qp.jsonBuf = writeProfileObject(qp.jsonBuf, cols[0], cols[1], cols[2], cols[3])
			qp.jsonBuf = append(qp.jsonBuf, '}')
		}
	}
	if _, err := rr.Close(); err != nil {
		return err
	}
	for _, t := range batch {
		if t.plan.rowsSeen == 0 {
			finishWith(t, 404, msgProfile404)
		} else {
			t.finishJSON(200)
		}
	}
	s.engine.srv.completeAsyncBatch(batch)
	return nil
}

func (s *pgSession) decodeBatchFollowWrite(isFollow bool, batch []*reqCtx, rr *pgconn.ResultReader) error {
	count := len(batch)
	flag := pgBoolFalse
	if isFollow {
		flag = pgBoolTrue
	}
	for _, t := range batch {
		t.plan.rowsSeen = 0
		t.plan.nextAction = stepRespond
	}
	for rr.NextRow() {
		cols := rr.Values()
		slot := int(decodePGInt8(cols[3])) - 1
		if uint(slot) < uint(count) {
			t := batch[slot]
			qp := &t.plan
			qp.rowsSeen = 1
			qp.jsonBuf = append(qp.jsonBuf[:0], `{"profile":`...)
			qp.jsonBuf = writeProfileObject(qp.jsonBuf, cols[0], cols[1], cols[2], flag)
			qp.jsonBuf = append(qp.jsonBuf, '}')
		}
	}
	if _, err := rr.Close(); err != nil {
		return err
	}
	for _, t := range batch {
		if t.plan.rowsSeen == 0 {
			finishWith(t, 404, msgProfile404)
		} else {
			t.finishJSON(200)
		}
	}
	return nil
}

func writeUserPrefix(dst, username, email, bio, image []byte) []byte {
	dst = append(dst, `{"user":{"email":`...)
	dst = writeJSONStr(dst, email)
	dst = append(dst, `,"username":`...)
	dst = writeJSONStr(dst, username)
	dst = append(dst, `,"bio":`...)
	dst = writeOptJSONStr(dst, bio)
	dst = append(dst, `,"image":`...)
	dst = writeOptJSONStr(dst, image)
	return append(dst, `,"token":"`...)
}

func writeUserObject(dst, username, email, bio, image, token []byte) []byte {
	dst = writeUserPrefix(dst, username, email, bio, image)
	dst = append(dst, token...)
	return append(dst, `"}}`...)
}

func writeProfileObject(dst, username, bio, image, following []byte) []byte {
	dst = append(dst, `{"username":`...)
	dst = writeJSONStr(dst, username)
	dst = append(dst, `,"bio":`...)
	dst = writeOptJSONStr(dst, bio)
	dst = append(dst, `,"image":`...)
	dst = writeOptJSONStr(dst, image)
	dst = append(dst, `,"following":`...)
	if following == nil {
		dst = append(dst, "false"...)
	} else {
		dst = writeJSONBool(dst, following)
	}
	return append(dst, '}')
}
