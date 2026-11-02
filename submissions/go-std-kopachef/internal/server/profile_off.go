//go:build !profile

package server

type readTimingProfile struct{}

func profileClock() int64                    { return 0 }
func profileReadEnter(*queuedRead)           {}
func profileReadAdmission(*queuedRead)       {}
func profileReadLeave(*queuedRead)           {}
func profileReadExecute([]*queuedRead) int64 { return 0 }
func profileReadStage(int, int64)            {}
func profileResponseEncode(int64)            {}
func profileResponseWrite(int64)             {}
func profileWriteAdmission(*writeJob)        {}
func profileWriteReady(*writeJob)            {}
func profileWriteExecute([]*writeJob) int64  { return 0 }
func profileWriteDone(int64)                 {}

func startProfiling(*app) func()            { return func() {} }
func recordReadBatch(int, int)              {}
func recordArticleBatch(int, int)           {}
func recordArticleFlags(int, int)           {}
func recordCommentBatch(int, int, int, int) {}
func recordPasswordBatch(int)               {}
func recordJSONBody(int)                    {}
func recordFavoriteBatch(int, int)          {}
func recordWriteBatch(int, int)             {}
func recordHTTPResponseBuffer(bool)         {}
func recordCompactAPIRead()                 {}
