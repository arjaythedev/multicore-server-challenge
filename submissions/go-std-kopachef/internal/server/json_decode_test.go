package server

import (
	"fmt"
	"reflect"
	"strings"
	"testing"
)

func compareRequestDecoders(t *testing.T, body []byte) {
	t.Helper()
	got, gotErr := decodeRequestFields(body, "user")
	want, wantErr := decodeRequestFieldsStandard(body, "user")
	if (gotErr == nil) != (wantErr == nil) || (gotErr == nil && !reflect.DeepEqual(got, want)) {
		t.Fatalf("decode %q: got %v (%v), want %v (%v)", body, got, gotErr, want, wantErr)
	}
}

func TestRequestDecoder(t *testing.T) {
	for _, text := range []string{
		``, `null`, `{}`, `[]`, `{"user":null}`, `{"User":{}}`, `{"user":[]}`,
		`{"user":{}}`, `{"other":{"unknown":[true,false,null,1.25e+3]},"user":{"name":"λ\""}}`,
		`{"user":{"a":null,"b":["tag",{"x":1}],"c":true}}`,
		`{"user":1,"user":{"name":"last"}}`, `{"user":{},"user":null}`,
		`{"user":{"a":1,"a":2}}`, `{"\u0075ser":{"\u0061":1,"a":2}}`,
		` { "user" : { "name" : "a" , "value" : [ 1, 2 ] } } `,
		`{"user":{}} {}`, `{"user":{},}`, `{"user":{"a":01}}`, `{"user":{"a":NaN}}`,
		`{"user":{"name":"\ud800"}}`, "{\"user\":{\"name\":\"\xff\"}}",
		`{"user":{"empty":"","null":null},"user":{"name":"overwrite"}}`,
		`{"user":{"a":"` + strings.Repeat("value", 40000) + `","b":2}}`,
		`{"other":` + strings.Repeat(`[`, 10001) + `0` + strings.Repeat(`]`, 10001) + `,"user":{}}`,
	} {
		compareRequestDecoders(t, []byte(text))
	}
}

func FuzzRequestDecoder(f *testing.F) {
	for _, text := range []string{`{"user":{"email":"x","password":"y"}}`, `{"user":{}}`, `null`, `{"user":null,"user":{"a":1}}`} {
		f.Add([]byte(text))
	}
	f.Fuzz(func(t *testing.T, body []byte) { compareRequestDecoders(t, body) })
}

func BenchmarkRequestDecoder(b *testing.B) {
	bodies := []string{
		`{"user":{"email":"an-email@example.test","password":"somepassword"}}`,
		`{"article":{"title":"A title","description":"A description","body":"` + strings.Repeat(`a line\n`, 100) + `","tagList":["go","postgres"]}}`,
		`{"user":{"bio":null,"image":"https://example.test/image.png","username":"λ\"\\"}}`,
	}
	for i, text := range bodies {
		key := "user"
		if i == 1 {
			key = "article"
		}
		for _, mode := range []string{"standard", "stream"} {
			b.Run(fmt.Sprintf("%s/body%d", mode, i), func(b *testing.B) {
				body := []byte(text)
				b.ReportAllocs()
				for b.Loop() {
					var err error
					if mode == "stream" {
						_, err = decodeRequestFields(body, key)
					} else {
						_, err = decodeRequestFieldsStandard(body, key)
					}
					if err != nil {
						b.Fatal(err)
					}
				}
			})
		}
	}
}
