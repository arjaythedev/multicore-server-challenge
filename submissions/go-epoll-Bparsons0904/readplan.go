package main

import (
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"

	"multicorelab/http/conduit"
)

// Read families, the units a CONDUIT_READ_PLAN assigns to groups of readers.
const (
	rfGlobal    = iota // the global article list
	rfTagList          // articles of a tag
	rfAuthor           // articles of an author
	rfFavorited        // articles a user favorited
	rfFeed             // the viewer's feed
	rfArticle          // one article
	rfComments         // an article's comments
	rfProfile          // a profile
	rfUser             // the current user
	rfTags             // the tag list
	rfLogin            // login lookups
	nReadFams
)

var readFamNames = [nReadFams]string{"global", "taglist", "author", "favorited", "feed", "article", "comments", "profile", "user", "tags", "login"}

// defaultReadPlan gives the busiest read families their own readers (global, feed and comments two each) and
// shares one reader between the single-key reads and one between the filtered lists and logins. An explicit
// CONDUIT_READ_PLAN overrides it; set but empty, it restores the single read queue.
const defaultReadPlan = "global=2;feed=2;comments=2;article,profile,user,tags=1;taglist,author,favorited,login=1"

var readPlan = func() string {
	if v, ok := os.LookupEnv("CONDUIT_READ_PLAN"); ok {
		return strings.TrimSpace(v)
	}
	return defaultReadPlan
}()

// readFamOf names the family of a read request.
func readFamOf(c *conduit.Call) int {
	switch c.Endpoint {
	case conduit.ListArticles:
		switch c.Filter {
		case conduit.ByTag:
			return rfTagList
		case conduit.ByAuthor:
			return rfAuthor
		case conduit.ByFavorited:
			return rfFavorited
		}
		return rfGlobal
	case conduit.Feed:
		return rfFeed
	case conduit.GetArticle:
		return rfArticle
	case conduit.ListComments:
		return rfComments
	case conduit.GetProfile:
		return rfProfile
	case conduit.GetUser:
		return rfUser
	case conduit.Login:
		return rfLogin
	}
	return rfTags
}

// planGroup is one read group of a plan: its families and its number of readers.
type planGroup struct {
	fams    []int
	readers int
}

// parsePlan reads "global=2;feed=2;article,profile=1": groups separated by ';', each a comma list of family names,
// '=' and its reader count. A family left out joins the last group.
func parsePlan(spec string) ([]planGroup, error) {
	var groups []planGroup
	seen := [nReadFams]bool{}
	for _, part := range strings.Split(spec, ";") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		names, n, ok := strings.Cut(part, "=")
		n = strings.TrimSpace(n)
		readers, err := strconv.Atoi(n)
		if !ok || err != nil || readers < 1 {
			return nil, fmt.Errorf("group %q: want families=readers with readers >= 1", part)
		}
		g := planGroup{readers: readers}
		for _, name := range strings.Split(names, ",") {
			name = strings.TrimSpace(name)
			f := -1
			for i, fn := range readFamNames {
				if fn == name {
					f = i
				}
			}
			if f < 0 || seen[f] {
				return nil, fmt.Errorf("group %q: unknown or repeated family %q (families: %s)", part, name, strings.Join(readFamNames[:], ", "))
			}
			seen[f] = true
			g.fams = append(g.fams, f)
		}
		groups = append(groups, g)
	}
	if len(groups) == 0 || len(groups) > maxGroups {
		return nil, fmt.Errorf("want 1 to %d groups", maxGroups)
	}
	last := &groups[len(groups)-1]
	for f, s := range seen {
		if !s {
			log.Printf("read plan: family %s not listed, joins the last group", readFamNames[f])
			last.fams = append(last.fams, f)
		}
	}
	return groups, nil
}
