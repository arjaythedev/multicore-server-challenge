//go:build arenapoison

package main

// poison overwrites everything the arena handed out, so a string or row read after its flush shows up as garbage in
// the differ. Built with -tags arenapoison only.
func (a *arena) poison() {
	for _, c := range a.chunks {
		c = c[:cap(c)]
		for i := range c {
			c[i] = 'Z'
		}
	}
	for _, c := range a.strs {
		for i := range c {
			c[i] = "POISON"
		}
	}
	for _, c := range a.arts {
		for i := range c {
			c[i] = artRow{id: -1, authorID: -1, slug: "POISON", title: "POISON", desc: "POISON", body: "POISON", username: "POISON", tags: []string{"POISON"}}
		}
	}
}
