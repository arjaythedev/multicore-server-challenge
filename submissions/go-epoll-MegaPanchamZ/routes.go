package main

import (
	"bytes"
	"encoding/json/jsontext"
	jsonv2 "encoding/json/v2"
	"errors"
	"log"
	"net/url"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5/pgconn"
)

const maxRetainedBytes = 64 << 10

type opCode uint8

const (
	opUnmatched opCode = iota
	opGetTags
	opPostLogin
	opPostRegister
	opGetProfile
	opGetArticles
	opGetArticle
	opGetComments
	opGetCurrentUser
	opPutCurrentUser
	opPostFollow
	opDeleteFollow
	opGetFeed
	opPostArticle
	opPutArticle
	opDeleteArticle
	opPostFavorite
	opDeleteFavorite
	opPostComment
	opDeleteComment
)

type nextStep uint8

const (
	stepRespond nextStep = iota
	stepRunSQL
	stepHashPass
	stepCheckPass
)

type authPolicy uint8

const (
	policyPublic authPolicy = iota
	policyOptional
	policyRequired
)

type httpReq struct {
	verb, path, rawURI   string
	body, authHeader     []byte
	authCount            int
	slugParam, userParam string
	commentIDParam       string
	query                urlQuery
}

type urlQuery struct {
	raw    string
	parsed url.Values
	useMap bool
}

func (uq *urlQuery) bindQuery(raw string) {
	uq.raw = raw
	uq.parsed = nil
	uq.useMap = false
	for i := 0; i < len(raw); i++ {
		switch raw[i] {
		case '%', '+', ';':
			uq.parsed, _ = url.ParseQuery(raw)
			uq.useMap = true
			return
		}
	}
}

func (uq *urlQuery) getParam(name string) (string, bool) {
	if uq.useMap {
		vals, ok := uq.parsed[name]
		if !ok {
			return "", false
		}
		return vals[0], true
	}
	rem := uq.raw
	for rem != "" {
		var kv string
		kv, rem, _ = strings.Cut(rem, "&")
		if kv == "" {
			continue
		}
		k, v, _ := strings.Cut(kv, "=")
		if k == name {
			return v, true
		}
	}
	return "", false
}

func (uq *urlQuery) getOrEmpty(name string) string {
	v, _ := uq.getParam(name)
	return v
}

func (r *httpReq) bindURI(verb, uri []byte) {
	r.verb = bytesToStr(verb)
	r.rawURI = bytesToStr(uri)
	r.path = r.rawURI
	var qStr string
	if qIdx := strings.IndexByte(r.path, '?'); qIdx >= 0 {
		qStr = r.path[qIdx+1:]
		r.path = r.path[:qIdx]
	}
	r.query.bindQuery(qStr)
}

func decodePathParam(seg string) string {
	if strings.IndexByte(seg, '%') < 0 {
		return seg
	}
	val, err := url.PathUnescape(seg)
	if err != nil {
		return ""
	}
	return val
}

func parsePositiveInt(s string) (int64, bool) {
	if s == "" {
		return 0, false
	}
	if len(s) <= 18 {
		var acc int64
		for i := 0; i < len(s); i++ {
			d := s[i] - '0'
			if d > 9 {
				return 0, false
			}
			acc = acc*10 + int64(d)
		}
		return acc, true
	}
	for i := 0; i < len(s); i++ {
		if s[i]-'0' > 9 {
			return 0, false
		}
	}
	n, err := strconv.ParseInt(s, 10, 64)
	return n, err == nil
}

func parsePageParams(r *httpReq) (limit, offset int64, valid bool) {
	limit, offset = 20, 0
	if rawLim, ok := r.query.getParam("limit"); ok {
		v, okNum := parsePositiveInt(rawLim)
		if !okNum || v < 1 || v > 100 {
			return 0, 0, false
		}
		limit = v
	}
	if rawOff, ok := r.query.getParam("offset"); ok {
		v, okNum := parsePositiveInt(rawOff)
		if !okNum {
			return 0, 0, false
		}
		offset = v
	}
	return limit, offset, true
}

func isDuplicateKeyErr(err error) bool {
	var pge *pgconn.PgError
	return errors.As(err, &pge) && pge.Code == "23505"
}

func validUTF8Text(s string) bool {
	return utf8.ValidString(s) && strings.IndexByte(s, 0) < 0
}

func noNullByte(s string) bool {
	return strings.IndexByte(s, 0) < 0
}

type queryPlan struct {
	op         opCode
	sqlID      sqlOp
	viewerID   int64
	rawToken   []byte
	userForm   userFormInput
	passHashed bool
	nextAction nextStep

	bindArgs   [6][]byte
	bindCount  int
	intScratch [6][8]byte
	arrayBuf   []byte

	bcryptBuf  [60]byte
	bcryptLen  int
	matchedUID int64

	rowsSeen    int
	totalRows   int64
	parentFound bool

	jsonBuf []byte
}

type userFormInput struct {
	email, username, password, bio, image                string
	hasEmail, hasUsername, hasPassword, hasBio, hasImage bool
}

func (qp *queryPlan) clearState() {
	if cap(qp.jsonBuf) > maxRetainedBytes {
		qp.jsonBuf = nil
	} else {
		qp.jsonBuf = qp.jsonBuf[:0]
	}
	if cap(qp.arrayBuf) > maxRetainedBytes {
		qp.arrayBuf = nil
	} else {
		qp.arrayBuf = qp.arrayBuf[:0]
	}
	clear(qp.bindArgs[:qp.bindCount])
	qp.op = 0
	qp.sqlID = 0
	qp.viewerID = 0
	qp.rawToken = nil
	qp.userForm = userFormInput{}
	qp.passHashed = false
	qp.nextAction = 0
	qp.bindCount = 0
	qp.bcryptLen = 0
	qp.matchedUID = 0
	qp.rowsSeen = 0
	qp.totalRows = 0
	qp.parentFound = false
}

func (qp *queryPlan) bindInt8(v int64) {
	qp.bindArgs[qp.bindCount] = encodePGInt8(&qp.intScratch[qp.bindCount], v)
	qp.bindCount++
}

func (qp *queryPlan) bindText(s string) {
	qp.bindArgs[qp.bindCount] = strToBytes(s)
	qp.bindCount++
}

func (qp *queryPlan) bindNullableText(s string, present bool) {
	if present {
		qp.bindArgs[qp.bindCount] = strToBytes(s)
	} else {
		qp.bindArgs[qp.bindCount] = nil
	}
	qp.bindCount++
}

func (qp *queryPlan) bindRawBytes(b []byte) {
	qp.bindArgs[qp.bindCount] = b
	qp.bindCount++
}

func (qp *queryPlan) hashedSlice() []byte {
	if !qp.passHashed {
		return nil
	}
	return qp.bcryptBuf[:qp.bcryptLen]
}

func finishWith(t *reqCtx, status int, body []byte) nextStep {
	t.reply.code = status
	t.reply.payload = body
	return stepRespond
}

func (t *reqCtx) finishJSON(status int) nextStep {
	return finishWith(t, status, t.plan.jsonBuf)
}

func matchRoute(r *httpReq) opCode {
	verb, path := r.verb, r.path
	isRead := verb == "GET" || verb == "HEAD"

	if !strings.HasPrefix(path, "/api/") {
		return opUnmatched
	}
	sub := path[5:]
	switch sub {
	case "tags":
		if isRead {
			return opGetTags
		}
		return opUnmatched
	case "users":
		if verb == "POST" {
			return opPostRegister
		}
		return opUnmatched
	case "users/login":
		if verb == "POST" {
			return opPostLogin
		}
		return opUnmatched
	case "user":
		if isRead {
			return opGetCurrentUser
		}
		if verb == "PUT" {
			return opPutCurrentUser
		}
		return opUnmatched
	case "articles":
		if isRead {
			return opGetArticles
		}
		if verb == "POST" {
			return opPostArticle
		}
		return opUnmatched
	case "articles/feed":
		if isRead {
			return opGetFeed
		}
		return opUnmatched
	}

	if profRest, ok := strings.CutPrefix(sub, "profiles/"); ok {
		uname, action, hasSlash := strings.Cut(profRest, "/")
		if uname == "" {
			return opUnmatched
		}
		r.userParam = decodePathParam(uname)
		if !hasSlash {
			if isRead {
				return opGetProfile
			}
			return opUnmatched
		}
		if action == "follow" {
			if verb == "POST" {
				return opPostFollow
			}
			if verb == "DELETE" {
				return opDeleteFollow
			}
		}
		return opUnmatched
	}

	if artRest, ok := strings.CutPrefix(sub, "articles/"); ok {
		slug, suffix, hasSlash := strings.Cut(artRest, "/")
		if slug == "" {
			return opUnmatched
		}
		r.slugParam = decodePathParam(slug)
		if !hasSlash {
			switch {
			case isRead:
				return opGetArticle
			case verb == "PUT":
				return opPutArticle
			case verb == "DELETE":
				return opDeleteArticle
			default:
				return opUnmatched
			}
		}
		switch suffix {
		case "favorite":
			if verb == "POST" {
				return opPostFavorite
			}
			if verb == "DELETE" {
				return opDeleteFavorite
			}
		case "comments":
			if isRead {
				return opGetComments
			}
			if verb == "POST" {
				return opPostComment
			}
		default:
			if cid, ok := strings.CutPrefix(suffix, "comments/"); ok && cid != "" && !strings.Contains(cid, "/") && verb == "DELETE" {
				r.commentIDParam = decodePathParam(cid)
				return opDeleteComment
			}
		}
	}
	return opUnmatched
}

func routeAuthPolicy(op opCode) authPolicy {
	switch op {
	case opGetTags, opPostLogin, opPostRegister:
		return policyPublic
	case opGetProfile, opGetArticles, opGetArticle, opGetComments:
		return policyOptional
	default:
		return policyRequired
	}
}

func checkRequestAuth(signer *tokenSigner, t *reqCtx, mustAuth bool) bool {
	r := &t.req
	if r.authCount == 0 {
		return !mustAuth
	}
	if r.authCount > 1 {
		return false
	}
	tokStr, ok := strings.CutPrefix(bytesToStr(r.authHeader), "Token ")
	if !ok {
		return false
	}
	uid, valid := signer.verifyToken(strToBytes(tokStr))
	if !valid {
		return false
	}
	t.plan.viewerID = uid
	t.plan.rawToken = strToBytes(tokStr)
	return true
}

func prepareRequest(signer *tokenSigner, t *reqCtx) nextStep {
	qp := &t.plan
	if !qp.passHashed {
		if !unpackTaskRequest(t) {
			return stepRespond
		}
		qp.op = matchRoute(&t.req)
		if qp.op == opUnmatched {
			return finishWith(t, 404, msgNotFound)
		}
		pol := routeAuthPolicy(qp.op)
		if pol != policyPublic && !checkRequestAuth(signer, t, pol == policyRequired) {
			return finishWith(t, 401, msgUnauthorized)
		}
	}
	qp.bindCount = 0
	switch qp.op {
	case opGetTags:
		return prepGetTags(t)
	case opGetCurrentUser:
		return prepCurrentUser(t)
	case opPutCurrentUser:
		return prepUpdateUser(t)
	case opPostLogin:
		return prepLogin(t)
	case opPostRegister:
		return prepRegister(t)
	case opGetProfile:
		return prepGetProfile(t)
	case opPostFollow:
		return prepFollowUser(t)
	case opDeleteFollow:
		return prepUnfollowUser(t)
	case opGetArticles:
		return prepListArticles(t)
	case opGetFeed:
		return prepFeedArticles(t)
	case opGetArticle:
		return prepGetArticle(t)
	case opPostArticle:
		return prepCreateArticle(t)
	case opPutArticle:
		return prepUpdateArticle(t)
	case opDeleteArticle:
		return prepDeleteArticle(t)
	case opPostFavorite:
		return prepFavoriteArticle(t)
	case opDeleteFavorite:
		return prepUnfavoriteArticle(t)
	case opGetComments:
		return prepGetComments(t)
	case opPostComment:
		return prepCreateComment(t)
	case opDeleteComment:
		return prepDeleteComment(t)
	default:
		return finishWith(t, 404, msgNotFound)
	}
}

type rowOutcome struct {
	httpCode int
	errBytes []byte
	followup nextStep
}

func okOutcome(code int) rowOutcome              { return rowOutcome{httpCode: code} }
func errOutcome(code int, msg []byte) rowOutcome { return rowOutcome{httpCode: code, errBytes: msg} }

func (s *pgSession) completeSingleResult(t *reqCtx, rr *pgconn.ResultReader) (nextStep, error) {
	qp := &t.plan
	qp.jsonBuf = qp.jsonBuf[:0]
	var out rowOutcome
	switch qp.op {
	case opGetTags:
		out = decodeTagsRow(t, rr)
	case opGetCurrentUser:
		out = decodeCurrentUserRow(t, rr)
	case opPutCurrentUser:
		out = decodeUpdateUserRow(t, rr)
	case opPostLogin:
		out = decodeLoginRow(t, rr)
	case opPostRegister:
		out = decodeRegisterRow(s, t, rr)
	case opGetProfile:
		out = decodeProfileRow(t, rr)
	case opPostFollow:
		out = decodeFollowRow(t, rr, true)
	case opDeleteFollow:
		out = decodeFollowRow(t, rr, false)
	case opGetArticles, opGetFeed:
		out = decodeArticleListRows(t, rr)
	case opGetArticle, opPostFavorite, opDeleteFavorite:
		out = decodeArticleRow(t, rr, 200)
	case opPostArticle:
		out = decodeArticleRow(t, rr, 201)
	case opPutArticle:
		out = decodeUpdateArticleRow(t, rr)
	case opDeleteArticle:
		out = decodeDeleteRow(t, rr, msgArticle404)
	case opGetComments:
		out = decodeCommentRows(t, rr)
	case opPostComment:
		out = decodeCreatedCommentRow(t, rr)
	case opDeleteComment:
		out = decodeDeleteRow(t, rr, msgComment404)
	default:
		out = errOutcome(404, msgNotFound)
	}
	if _, err := rr.Close(); err != nil {
		return stepRespond, err
	}
	switch {
	case out.errBytes != nil:
		finishWith(t, out.httpCode, out.errBytes)
	case out.httpCode == 204:
		finishWith(t, 204, nil)
	default:
		t.finishJSON(out.httpCode)
	}
	return out.followup, nil
}

func (s *pgSession) handleQueryError(t *reqCtx, err error) {
	if (t.plan.op == opPostRegister || t.plan.op == opPutCurrentUser) && isDuplicateKeyErr(err) {
		finishWith(t, 422, msgDuplicateUser)
		return
	}
	log.Printf("query error (op=%d): %v", t.plan.op, err)
	finishWith(t, 500, msgServerError)
}

func (s *pgSession) completeBatchReads(op sqlOp, batch []*reqCtx, rr *pgconn.ResultReader) error {
	switch op {
	case opTags:
		return s.decodeBatchTags(batch, rr)
	case opUserByID:
		return s.decodeBatchUserByID(batch, rr)
	case opUserByEmail:
		return s.decodeBatchUserByEmail(batch, rr)
	case opProfile:
		return s.decodeBatchProfile(batch, rr)
	case opArticle:
		return s.decodeBatchArticle(batch, rr)
	case opComments:
		return s.decodeBatchComments(batch, rr)
	case opListAll, opListTag, opListAuthor, opListFav, opListFeed:
		return s.decodeBatchArticleList(batch, rr)
	default:
		return nil
	}
}

func (s *pgSession) completeBatchWrites(op sqlOp, batch []*reqCtx, rr *pgconn.ResultReader) error {
	switch op {
	case opFollow, opUnfollow:
		return s.decodeBatchFollowWrite(op == opFollow, batch, rr)
	case opFavorite, opUnfavorite:
		return s.decodeBatchFavoriteWrite(batch, rr)
	case opCommentCreate:
		return s.decodeBatchCommentWrite(batch, rr)
	default:
		return nil
	}
}

// ---------- JSON request body scanner ----------

var errMalformedJSON = errors.New("invalid json body")

type scannedAttr struct {
	text    string
	defined bool
	isNull  bool
}

type bodyEnvelope struct {
	email, username, password, bio, image scannedAttr
	title, description, body              scannedAttr
	hasTags                               bool
	tagCount                              int
	inlineTags                            [16]string
	extraTags                             []string
	fallback                              map[string]jsontext.Value
}

func (env *bodyEnvelope) requiredStr(attr scannedAttr, key string) (string, error) {
	if env.fallback != nil {
		return mapRequiredStr(env.fallback, key)
	}
	if !attr.defined || attr.isNull || attr.text == "" {
		return "", errMalformedJSON
	}
	return attr.text, nil
}

func (env *bodyEnvelope) optionalStr(attr scannedAttr, key string, rejectEmpty bool) (string, bool, error) {
	if env.fallback != nil {
		ptr, err := mapOptionalStr(env.fallback, key, rejectEmpty)
		if err != nil || ptr == nil {
			return "", false, err
		}
		return *ptr, true, nil
	}
	if !attr.defined || attr.isNull {
		return "", false, nil
	}
	if rejectEmpty && attr.text == "" {
		return "", false, errMalformedJSON
	}
	return attr.text, true, nil
}

func (env *bodyEnvelope) extractTags() ([]string, []byte) {
	if env.fallback != nil {
		return mapExtractTags(env.fallback)
	}
	if env.extraTags != nil {
		return env.extraTags, nil
	}
	return env.inlineTags[:env.tagCount], nil
}

func readSimpleJSONStr(b []byte, pos int) (string, int, bool) {
	raw, next, ok := readASCIIQuote(b, pos)
	if !ok {
		return "", next, false
	}
	return bytesToStr(raw), next, true
}

func readJSONNull(b []byte, pos int) (int, bool) {
	if pos+4 <= len(b) && string(b[pos:pos+4]) == "null" {
		return pos + 4, true
	}
	return pos, false
}

func decodeEnvelope(r *httpReq, outerKey string, dst *bodyEnvelope) error {
	*dst = bodyEnvelope{}
	raw := r.body
	if len(raw) > 1<<20 {
		return errMalformedJSON
	}
	if scanFastEnvelope(raw, outerKey, dst) {
		return nil
	}
	*dst = bodyEnvelope{}
	m, err := unmarshalOuterMap(raw, outerKey)
	if err != nil {
		return err
	}
	dst.fallback = m
	return nil
}

func scanFastEnvelope(b []byte, outerKey string, dst *bodyEnvelope) bool {
	pos := skipSpaces(b, 0)
	if pos >= len(b) || b[pos] != '{' {
		return false
	}
	pos = skipSpaces(b, pos+1)
	topKey, nextPos, ok := readSimpleJSONStr(b, pos)
	if !ok || topKey != outerKey {
		return false
	}
	pos = skipSpaces(b, nextPos)
	if pos >= len(b) || b[pos] != ':' {
		return false
	}
	pos = skipSpaces(b, pos+1)
	if pos >= len(b) || b[pos] != '{' {
		return false
	}
	pos = skipSpaces(b, pos+1)
	if pos < len(b) && b[pos] == '}' {
		pos = skipSpaces(b, pos+1)
		return pos < len(b) && b[pos] == '}' && skipSpaces(b, pos+1) == len(b)
	}
	for {
		fieldKey, afterKey, okKey := readSimpleJSONStr(b, pos)
		if !okKey {
			return false
		}
		pos = skipSpaces(b, afterKey)
		if pos >= len(b) || b[pos] != ':' {
			return false
		}
		pos = skipSpaces(b, pos+1)
		if fieldKey == "tagList" {
			if dst.hasTags {
				return false
			}
			dst.hasTags = true
			if afterNull, isN := readJSONNull(b, pos); isN {
				pos = afterNull
			} else if pos < len(b) && b[pos] == '[' {
				pos = skipSpaces(b, pos+1)
				if pos < len(b) && b[pos] == ']' {
					pos++
				} else {
					for {
						tagVal, afterTag, okTag := readSimpleJSONStr(b, pos)
						if !okTag || tagVal == "" {
							return false
						}
						if dst.extraTags != nil {
							dst.extraTags = append(dst.extraTags, tagVal)
						} else if dst.tagCount < len(dst.inlineTags) {
							dst.inlineTags[dst.tagCount] = tagVal
							dst.tagCount++
						} else {
							dst.extraTags = make([]string, dst.tagCount+1, 32)
							copy(dst.extraTags, dst.inlineTags[:])
							dst.extraTags[dst.tagCount] = tagVal
						}
						pos = skipSpaces(b, afterTag)
						if pos >= len(b) {
							return false
						}
						if b[pos] == ']' {
							pos++
							break
						}
						if b[pos] != ',' {
							return false
						}
						pos = skipSpaces(b, pos+1)
					}
				}
			} else {
				return false
			}
		} else {
			var target *scannedAttr
			switch fieldKey {
			case "email":
				target = &dst.email
			case "username":
				target = &dst.username
			case "password":
				target = &dst.password
			case "bio":
				target = &dst.bio
			case "image":
				target = &dst.image
			case "title":
				target = &dst.title
			case "description":
				target = &dst.description
			case "body":
				target = &dst.body
			default:
				return false
			}
			if target.defined {
				return false
			}
			if afterNull, isN := readJSONNull(b, pos); isN {
				*target = scannedAttr{defined: true, isNull: true}
				pos = afterNull
			} else if sVal, afterVal, okVal := readSimpleJSONStr(b, pos); okVal {
				*target = scannedAttr{text: sVal, defined: true}
				pos = afterVal
			} else {
				return false
			}
		}
		pos = skipSpaces(b, pos)
		if pos >= len(b) {
			return false
		}
		if b[pos] == '}' {
			pos = skipSpaces(b, pos+1)
			break
		}
		if b[pos] != ',' {
			return false
		}
		pos = skipSpaces(b, pos+1)
	}
	return pos < len(b) && b[pos] == '}' && skipSpaces(b, pos+1) == len(b)
}

var jsonV2Opts = jsontext.AllowDuplicateNames(true)

func unmarshalOuterMap(raw []byte, outerKey string) (map[string]jsontext.Value, error) {
	var root map[string]jsontext.Value
	if err := jsonv2.Unmarshal(raw, &root, jsonV2Opts); err != nil || root == nil {
		return nil, errMalformedJSON
	}
	innerRaw, ok := root[outerKey]
	if !ok {
		return nil, errMalformedJSON
	}
	var fields map[string]jsontext.Value
	if err := jsonv2.Unmarshal(innerRaw, &fields, jsonV2Opts); err != nil || fields == nil {
		return nil, errMalformedJSON
	}
	return fields, nil
}

func rawIsJSONNull(raw jsontext.Value) bool {
	return bytes.Equal(bytes.TrimSpace(raw), []byte("null"))
}

func mapOptionalStr(m map[string]jsontext.Value, key string, rejectEmpty bool) (*string, error) {
	raw, ok := m[key]
	if !ok || rawIsJSONNull(raw) {
		return nil, nil
	}
	var s string
	if err := jsonv2.Unmarshal(raw, &s, jsonV2Opts); err != nil {
		return nil, errMalformedJSON
	}
	if rejectEmpty && s == "" {
		return nil, errMalformedJSON
	}
	return &s, nil
}

func mapRequiredStr(m map[string]jsontext.Value, key string) (string, error) {
	ptr, err := mapOptionalStr(m, key, true)
	if err != nil || ptr == nil {
		return "", errMalformedJSON
	}
	return *ptr, nil
}

func mapExtractTags(m map[string]jsontext.Value) ([]string, []byte) {
	raw, ok := m["tagList"]
	if !ok || rawIsJSONNull(raw) {
		return nil, nil
	}
	var arr []jsontext.Value
	if err := jsonv2.Unmarshal(raw, &arr, jsonV2Opts); err != nil {
		return nil, msgBadTagList
	}
	out := make([]string, 0, len(arr))
	for _, elem := range arr {
		var s string
		if rawIsJSONNull(elem) || jsonv2.Unmarshal(elem, &s, jsonV2Opts) != nil || s == "" || !noNullByte(s) {
			return nil, msgBadTagList
		}
		out = append(out, s)
	}
	return out, nil
}
