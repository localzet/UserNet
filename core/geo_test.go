//go:build !cgo && !android

package core

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func maxMindTestDatabase(t *testing.T) []byte {
	t.Helper()
	var data bytes.Buffer
	data.Write([]byte{0, 0, 1, 0, 0, 1})
	data.Write(make([]byte, 16))
	data.WriteString("\xab\xcd\xefMaxMind.com")
	data.WriteByte(0xE3)
	data.WriteString("\x4anode_count\xc1\x01")
	data.WriteString("\x4brecord_size\xa1\x18")
	data.WriteString("\x4aip_version\xa1\x04")
	return data.Bytes()
}

func geoStatuses(t *testing.T, run func()) []GeoUpdateStatus {
	t.Helper()
	fake := &fakeConn{}
	previous := swapConn(fake)
	defer swapConn(previous)
	run()
	deadline := time.Now().Add(2 * time.Second)
	for {
		var statuses []GeoUpdateStatus
		for _, frame := range fake.frames(t) {
			var batch struct {
				Arguments []struct {
					Type MessageType     `json:"type"`
					Data GeoUpdateStatus `json:"data"`
				} `json:"arguments"`
			}
			if err := json.Unmarshal(frame, &batch); err != nil {
				t.Fatalf("frame is not a message batch: %v", err)
			}
			for _, message := range batch.Arguments {
				if message.Type == GeoUpdateMessage {
					statuses = append(statuses, message.Data)
				}
			}
		}
		if len(statuses) >= 2 || time.Now().After(deadline) {
			return statuses
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func stubGeoResource(t *testing.T, update func(path string) error) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "ASN.mmdb")
	if err := os.WriteFile(path, []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	previous := geoResources["ASN"]
	geoResources["ASN"] = geoResource{
		update: func() error { return update(path) },
		url:    previous.url,
		setUrl: previous.setUrl,
		path:   func() string { return path },
	}
	t.Cleanup(func() { geoResources["ASN"] = previous })
	return path
}

func manualGeoUpdate(t *testing.T) []GeoUpdateStatus {
	t.Helper()
	return geoStatuses(t, func() {
		if err := handleUpdateGeoData("ASN"); err != nil {
			t.Fatalf("handleUpdateGeoData: %v", err)
		}
		waitForGeoRelease(t, "ASN")
	})
}

func waitForGeoRelease(t *testing.T, geoType string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for !claimGeoUpdate(geoType) {
		if time.Now().After(deadline) {
			t.Fatalf("%s update never released its claim", geoType)
		}
		time.Sleep(time.Millisecond)
	}
	releaseGeoUpdate(geoType)
}

func TestManualGeoUpdateReportsAnUnchangedFileAsSkipped(t *testing.T) {
	stubGeoResource(t, func(string) error { return nil })
	statuses := manualGeoUpdate(t)
	want := []GeoUpdateStatus{
		{Type: "ASN", Updating: true},
		{Type: "ASN", Skipped: true},
	}
	if len(statuses) != 2 || statuses[0] != want[0] || statuses[1] != want[1] {
		t.Fatalf("statuses = %+v, want %+v", statuses, want)
	}
}

func TestManualGeoUpdateReportsARewrittenFileAsUpdated(t *testing.T) {
	stubGeoResource(t, func(path string) error {
		return os.WriteFile(path, []byte("newer"), 0o644)
	})
	statuses := manualGeoUpdate(t)
	if len(statuses) != 2 || statuses[1] != (GeoUpdateStatus{Type: "ASN"}) {
		t.Fatalf("statuses = %+v, want an update that was not skipped", statuses)
	}
}

func TestManualGeoUpdateReportsTheError(t *testing.T) {
	stubGeoResource(t, func(string) error { return errors.New("offline") })
	statuses := manualGeoUpdate(t)
	if len(statuses) != 2 || statuses[1].Error != "offline" || statuses[1].Skipped {
		t.Fatalf("statuses = %+v, want the error reported", statuses)
	}
}

func TestMappedMaxMindUpdateWaitsForTheNextCoreStart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "GeoIP.mmdb")
	old := []byte("old database")
	if err := os.WriteFile(path, old, 0o644); err != nil {
		t.Fatal(err)
	}

	previous := stagesMappedFile
	stagesMappedFile = true
	t.Cleanup(func() { stagesMappedFile = previous })
	data := maxMindTestDatabase(t)
	if err := installMaxMindDatabase(path, data); err != nil {
		t.Fatalf("installMaxMindDatabase = %v", err)
	}
	if got, err := os.ReadFile(path); err != nil || !bytes.Equal(got, old) {
		t.Fatalf("active database changed before restart: err=%v", err)
	}
	if got, err := os.ReadFile(pendingGeoPath(path)); err != nil || !bytes.Equal(got, data) {
		t.Fatalf("pending database = %v, err=%v", got, err)
	}
	if geoFileInUse(path) != pendingGeoPath(path) {
		t.Fatal("pending database is not used for update comparisons")
	}

	if err := installPendingGeoFile(path); err != nil {
		t.Fatalf("installPendingGeoFile = %v", err)
	}
	if got, err := os.ReadFile(path); err != nil || !bytes.Equal(got, data) {
		t.Fatalf("restarted database = %v, err=%v", got, err)
	}
	if fileExists(pendingGeoPath(path)) {
		t.Fatal("pending database remained after installation")
	}
}
