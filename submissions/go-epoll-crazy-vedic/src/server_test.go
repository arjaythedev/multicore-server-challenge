package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"
	"testing"
	"time"
)

func TestConcurrentServerReadsAndTagCreation(t *testing.T) {
	if os.Getenv("TEST_DATABASE_URL") == "" {
		t.Skip("set TEST_DATABASE_URL")
	}
	pg, err := postgresConfig(os.Getenv("TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	cfg := reactorConfig{host: "127.0.0.1", loops: 2, workers: 4, active: 128, queued: 512, sockets: 4096, fdSlots: 8192,
		readTimeout: time.Second * 5, writeTimeout: time.Second * 5, idleTimeout: time.Second * 5, shutdownTimeout: time.Second * 5}
	secret := []byte("server-integration-secret")
	var d *dbDispatcher
	srv, err := newReactorServerWith(cfg, func(s *reactorServer) dispatcher {
		d = newDBDispatcher(s, dbConfig{readConns: 2, writeConns: 2, pipelineDepth: 2, readBatch: 32, writeBatch: 32,
			readQueue: 640, writeQueue: 640, bcryptQueue: 640, bcryptWorkers: 1, sharedReads: true, readAffinity: true, readRouteSlack: 8,
			queueTimeout: time.Second * 10, execTimeout: time.Second * 10, reconnectMin: time.Millisecond, reconnectMax: time.Millisecond * 10}, pg, secret)
		return d
	})
	if err != nil {
		t.Fatal(err)
	}
	if err = d.connectAll(context.Background()); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- srv.Serve(ctx) }()
	transport := &http.Transport{MaxIdleConns: 128, MaxIdleConnsPerHost: 128}
	client := &http.Client{Transport: transport, Timeout: time.Second * 10}
	t.Cleanup(func() {
		transport.CloseIdleConnections()
		cancel()
		select {
		case err := <-done:
			if err != nil {
				t.Error(err)
			}
		case <-time.After(time.Second * 15):
			t.Error("server did not drain")
		}
	})
	base := "http://" + srv.Addr()
	codec := newJWTCodec(secret)
	tokens := []string{string(codec.appendToken(nil, 1, time.Now())), string(codec.appendToken(nil, 2, time.Now()))}
	errors := make(chan error, 128)
	var wg sync.WaitGroup
	for i := 0; i < 64; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for k := 0; k < 16; k++ {
				path := "/api/tags"
				if k%2 != 0 {
					path = "/api/articles?limit=10"
				}
				req, _ := http.NewRequest("GET", base+path, nil)
				req.Header.Set("Authorization", "Token "+tokens[i%2])
				response, err := client.Do(req)
				if err != nil {
					errors <- err
					return
				}
				body, err := io.ReadAll(response.Body)
				response.Body.Close()
				if err != nil {
					errors <- err
					return
				}
				if response.StatusCode != 200 || !json.Valid(body) {
					errors <- fmt.Errorf("bad read: %d %s", response.StatusCode, body)
					return
				}
			}
		}(i)
	}
	wg.Wait()
	if len(errors) > 0 {
		t.Fatal(<-errors)
	}
	if d.metrics.executions.Load() >= d.metrics.jobs.Load() {
		t.Fatal("concurrent traffic never exercised shared reads")
	}
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			body := []byte(fmt.Sprintf(`{"article":{"title":"concurrent %d","description":"d","body":"b","tagList":["zenith_concurrent_b","zenith_concurrent_a"]}}`, i))
			req, _ := http.NewRequest("POST", base+"/api/articles", bytes.NewReader(body))
			req.Header.Set("Authorization", "Token "+tokens[i%2])
			req.Header.Set("Content-Type", "application/json")
			response, err := client.Do(req)
			if err != nil {
				errors <- err
				return
			}
			out, err := io.ReadAll(response.Body)
			response.Body.Close()
			if err != nil {
				errors <- err
				return
			}
			var article struct {
				Article struct {
					Tags []string `json:"tagList"`
				} `json:"article"`
			}
			if response.StatusCode != 201 || json.Unmarshal(out, &article) != nil || len(article.Article.Tags) != 2 {
				errors <- fmt.Errorf("concurrent tags: %d %s", response.StatusCode, out)
			}
		}(i)
	}
	wg.Wait()
	if len(errors) > 0 {
		t.Fatal(<-errors)
	}
}
