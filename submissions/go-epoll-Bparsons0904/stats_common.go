package main

// Statement families whose per-flush batch sizes are reported: the five page families, their counts, the single
// articles, the ids of round two, and the favorite and following probes.
const (
	famStatArticles = 2 * nFams
	famStatIDs      = famStatArticles + 1
	famStatFlagsFav = famStatArticles + 2
	famStatFlagsFol = famStatArticles + 3
	nFamStats       = famStatArticles + 4
)
