package main

import (
	"strconv"
	"strings"
)

// Input limits. The schema's text columns are unbounded, so without limits one
// request could store megabytes that every later page then has to send. The
// limits are generous for a blogging app and are checked before a write joins a
// shared group commit, so a bad value only ever fails its own request.
const (
	maxUsername    = 64
	maxEmail       = 254 // the longest address SMTP allows
	maxBio         = 4 << 10
	maxImage       = 2 << 10
	maxTitle       = 512
	maxDescription = 2 << 10
	maxArticleBody = 128 << 10
	maxCommentBody = 16 << 10
	maxTags        = 32
	maxTag         = 64
)

// textRule limits one string field. JSON decoding already guarantees valid
// UTF-8; control characters (including NUL, which PostgreSQL text cannot hold)
// are rejected, except line breaks and tabs in multi-line fields.
type textRule struct {
	name      string
	max       int
	multiline bool
	tooLong   []byte
	control   []byte
}

func newRule(name string, max int, multiline bool) *textRule {
	return &textRule{name: name, max: max, multiline: multiline,
		tooLong: errorJSON(name + " must be at most " + strconv.Itoa(max) + " bytes"),
		control: errorJSON(name + " must not contain control characters")}
}

var (
	ruleUsername    = newRule("username", maxUsername, false)
	ruleEmail       = newRule("email", maxEmail, false)
	ruleBio         = newRule("bio", maxBio, true)
	ruleImage       = newRule("image", maxImage, false)
	ruleTitle       = newRule("title", maxTitle, false)
	ruleDescription = newRule("description", maxDescription, true)
	ruleArticleBody = newRule("body", maxArticleBody, true)
	ruleCommentBody = newRule("body", maxCommentBody, true)
	ruleTag         = newRule("tag", maxTag, false)

	errEmailFormat = errorJSON("email must look like name@domain")
	errTooManyTags = errorJSON("tagList can hold at most " + strconv.Itoa(maxTags) + " tags")
)

// check returns the error body for a value that breaks the rule, or nil.
// A nil pointer is an absent optional field and always passes.
func (r *textRule) check(s *string) []byte {
	if s == nil {
		return nil
	}
	v := *s
	if len(v) > r.max {
		return r.tooLong
	}
	for i := 0; i < len(v); i++ {
		if c := v[i]; c < 0x20 || c == 0x7f {
			if r.multiline && (c == '\n' || c == '\r' || c == '\t') {
				continue
			}
			return r.control
		}
	}
	return nil
}

// checkEmail applies the email rule plus a minimal shape check: one '@' with
// something on each side and no spaces. Real verification is a mail round trip.
func checkEmail(s *string) []byte {
	if e := ruleEmail.check(s); e != nil || s == nil {
		return e
	}
	at := strings.IndexByte(*s, '@')
	if at <= 0 || at == len(*s)-1 || strings.LastIndexByte(*s, '@') != at || strings.IndexByte(*s, ' ') >= 0 {
		return errEmailFormat
	}
	return nil
}

func firstError(errs ...[]byte) []byte {
	for _, e := range errs {
		if e != nil {
			return e
		}
	}
	return nil
}
