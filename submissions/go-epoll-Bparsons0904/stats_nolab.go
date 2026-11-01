//go:build !lab

package main

import "multicorelab/http"

// The submission build keeps no counters, timings or samplers: every hook is empty and inlines away.
// stats_lab.go (go build -tags lab) has the real ones.

type labWorker struct{}

type statStamp struct{}

func statNow() statStamp              { return statStamp{} }
func statShared()                     {}
func statBcrypt(int)                  {}
func statFlush(int)                   {}
func statCommit(int)                  {}
func statPostRead(statStamp)          {}
func statTx(statStamp)                {}
func statReaders(int)                 {}
func statSteal(int)                   {}
func statReaderFlush(int, int)        {}
func statGroupFail()                  {}
func statFam(int, int, int)           {}
func statFlushEnd(*worker, statStamp) {}
func labStart(*DB, *http.Server)      {}
func labStop(*http.Server)            {}
