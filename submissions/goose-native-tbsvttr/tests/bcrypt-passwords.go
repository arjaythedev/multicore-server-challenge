// Trusted cost-10 interop helper for full passwords, including embedded NUL.
// Run from repo/bench with a temporary -modfile pinning golang.org/x/crypto
// v0.58.0; keep bench/go.mod and go.sum unchanged. The CI wrapper supplies this.
// It verifies stored hashes and generates independent hashes for reverse checks.
// It never starts a server or contacts a database.
package main

import (
    "encoding/json"
    "os"

    "golang.org/x/crypto/bcrypt"
)

type item struct {
    Password string `json:"password"`
    Prefix string `json:"prefix"`
    Hash string `json:"hash"`
}

func main() {
    var input struct { Items []item `json:"items"` }
    if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil { panic(err) }
    output := make([]map[string]interface{}, 0, len(input.Items))
    for _, in := range input.Items {
        cost, err := bcrypt.Cost([]byte(in.Hash))
        if err != nil { panic(err) }
        generated, err := bcrypt.GenerateFromPassword([]byte(in.Password), 10)
        if err != nil { panic(err) }
        output = append(output, map[string]interface{}{
            "password_bytes":len([]byte(in.Password)), "stored_cost":cost,
            "full_verify":bcrypt.CompareHashAndPassword([]byte(in.Hash), []byte(in.Password)) == nil,
            "prefix_verify":bcrypt.CompareHashAndPassword([]byte(in.Hash), []byte(in.Prefix)) == nil,
            "generated_hash":string(generated),
        })
    }
    if err := json.NewEncoder(os.Stdout).Encode(output); err != nil { panic(err) }
}
