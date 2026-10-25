// loadgen is the Conduit load generator for the multicore server challenge (see WORKLOAD.md).
//
//	loadgen run    -target http://10.0.0.2 -users 4000 -box-index 0 -id-offset 0 -start-at <unix ms> -secret S -out box0.json
//	loadgen merge  -o merged.json box0.json box1.json box2.json
//	loadgen search -target-ssh root@10.0.0.2 -target-url http://10.0.0.2 -lang go -secret S -outdir results/go
//
// Each virtual user is one goroutine with its own keep-alive TCP connection, following the TPC-W-style
// session/page model in DESIGN.md. Latencies go into HdrHistograms per endpoint; boxes are merged exactly.
package main

import (
	"fmt"
	"os"
)

const version = "loadgen/1"

func usage() {
	fmt.Fprintf(os.Stderr, `usage:
  loadgen run    [flags]   run virtual users on this box, write a results JSON
  loadgen merge  [flags]   merge box JSONs, print the verdict
  loadgen search [flags]   orchestrate warm-up, probes and holds across the load boxes
  loadgen <cmd> -h         flags of a subcommand
`)
	os.Exit(2)
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	args := os.Args[2:]
	switch os.Args[1] {
	case "run":
		os.Exit(cmdRun(args))
	case "merge":
		os.Exit(cmdMerge(args))
	case "search":
		os.Exit(cmdSearch(args))
	case "version", "-v", "--version":
		fmt.Println(version)
	default:
		usage()
	}
}
