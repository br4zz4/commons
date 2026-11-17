package hello

import "testing"

func TestGreet(t *testing.T) {
	if Greet("world") != "hello world" {
		t.Fatal("unexpected greeting")
	}
}
