package core

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestRetagShortIDsCopiesSharedAliasValues(t *testing.T) {
	profile := `mixed-port: &port 7890
proxies:
  - name: port-alias
    type: vless
    reality-opts: {public-key: k, short-id: *port}
  - name: short-id-anchor
    type: vless
    reality-opts: {public-key: k, short-id: &shared 7891}
redir-port: *shared
`

	raw, err := unmarshalRawConfig([]byte(profile))
	if err != nil {
		t.Fatalf("unmarshalRawConfig = %v", err)
	}
	if raw.MixedPort != 7890 || raw.RedirPort != 7891 {
		t.Fatalf("ports = mixed %d, redir %d; want 7890 and 7891", raw.MixedPort, raw.RedirPort)
	}
	for index, want := range []string{"7890", "7891"} {
		got := raw.Proxy[index]["reality-opts"].(map[string]any)["short-id"]
		if got != want {
			t.Errorf("proxy %d short-id = %#v, want %q", index, got, want)
		}
	}
}

func TestRetagShortIDListThatAliasesItselfReturns(t *testing.T) {
	done := make(chan error, 1)
	go func() {
		_, err := unmarshalRawConfig([]byte("x-template: {short-id: &ids [*ids]}\nmixed-port: 7890\n"))
		done <- err
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("retagging a self-referencing short-id list did not return")
	}
}

func TestHandleGetConfigKeepsAnUnquotedShortIDAsWritten(t *testing.T) {
	profile := `proxies:
  - name: octal
    type: vless
    reality-opts: {public-key: k, short-id: 0123}
  - name: zeros
    type: vless
    reality-opts:
      short-id: 00
  - name: exponent
    type: vless
    reality-opts:
      short-id: 1e5
  - name: quoted
    type: vless
    reality-opts:
      short-id: "0189"
  - name: hex
    type: vless
    reality-opts:
      short-id: 0a1b
listeners:
  - name: in
    type: vless
    reality-config:
      short-id: [01234567, ""]
`
	path := filepath.Join(t.TempDir(), "profile.yaml")
	if err := os.WriteFile(path, []byte(profile), 0o600); err != nil {
		t.Fatalf("write profile: %v", err)
	}

	raw, err := handleGetConfig(path)
	if err != nil {
		t.Fatalf("handleGetConfig = %v", err)
	}

	want := map[string]string{
		"octal":    "0123",
		"zeros":    "00",
		"exponent": "1e5",
		"quoted":   "0189",
		"hex":      "0a1b",
	}
	for _, proxy := range raw.Proxy {
		name := proxy["name"].(string)
		got := proxy["reality-opts"].(map[string]any)["short-id"]
		if got != want[name] {
			t.Errorf("%s short-id = %#v, want %q", name, got, want[name])
		}
	}
	ids := raw.Listeners[0]["reality-config"].(map[string]any)["short-id"].([]any)
	if ids[0] != "01234567" || ids[1] != "" {
		t.Errorf("listener short-id = %#v, want [01234567 \"\"]", ids)
	}
}

func TestHandleGetConfigLeavesProfilesWithoutShortIDsToMihomo(t *testing.T) {
	path := filepath.Join(t.TempDir(), "profile.yaml")
	if err := os.WriteFile(path, []byte("mixed-port: 7899\n"), 0o600); err != nil {
		t.Fatalf("write profile: %v", err)
	}

	raw, err := handleGetConfig(path)
	if err != nil {
		t.Fatalf("handleGetConfig = %v", err)
	}
	if raw.MixedPort != 7899 || raw.Mode.String() == "" {
		t.Errorf("raw config = port %d mode %q, want 7899 and the default mode", raw.MixedPort, raw.Mode)
	}
}
