package core

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/resource"
	"github.com/metacubex/mihomo/component/updater"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/oschwald/maxminddb-golang"
)

type geoResource struct {
	update func() error
	url    func() string
	setUrl func(string)
	path   func() string
}

var geoResources = map[string]geoResource{
	"MMDB":    {update: updateMMDB, url: geodata.MmdbUrl, setUrl: geodata.SetMmdbUrl, path: constant.Path.MMDB},
	"ASN":     {update: updateASN, url: geodata.ASNUrl, setUrl: geodata.SetASNUrl, path: constant.Path.ASN},
	"GEOIP":   {update: updater.UpdateGeoIp, url: geodata.GeoIpUrl, setUrl: geodata.SetGeoIpUrl, path: constant.Path.GeoIP},
	"GEOSITE": {update: updater.UpdateGeoSite, url: geodata.GeoSiteUrl, setUrl: geodata.SetGeoSiteUrl, path: constant.Path.GeoSite},
}

const geoDownloadTimeout = 90 * time.Second

var stagesMappedFile = runtime.GOOS == "windows"

func updateMMDB() error {
	if !stagesMappedFile {
		return updater.UpdateMMDB()
	}
	return updateMaxMindDatabase(geodata.MmdbUrl(), constant.Path.MMDB())
}

func updateASN() error {
	if !stagesMappedFile {
		return updater.UpdateASN()
	}
	return updateMaxMindDatabase(geodata.ASNUrl(), constant.Path.ASN())
}

func updateMaxMindDatabase(url string, path string) error {
	vehicle := resource.NewHTTPVehicle(url, path, "", nil, geoDownloadTimeout, 0)
	oldPath := geoFileInUse(path)
	var oldHash utils.HashType
	if current, err := os.ReadFile(oldPath); err == nil {
		oldHash = utils.MakeHash(current)
	}
	data, hash, err := vehicle.Read(context.Background(), oldHash)
	if err != nil {
		return fmt.Errorf("can't download database: %w", err)
	}
	if oldHash.Equal(hash) {
		return nil
	}
	if len(data) == 0 {
		return fmt.Errorf("can't download database: no data")
	}
	return installMaxMindDatabase(path, data)
}

func installMaxMindDatabase(path string, data []byte) error {
	validate := func(staged string) error {
		instance, err := maxminddb.Open(staged)
		if err == nil {
			err = instance.Close()
		}
		return err
	}
	target := path
	if stagesMappedFile {
		target = pendingGeoPath(path)
	}
	return replaceGeoFile(target, data, validate)
}

func replaceGeoFile(path string, data []byte, validate func(string) error) error {
	staged, err := writeSyncedTemp(path, data)
	if err != nil {
		return err
	}
	defer os.Remove(staged)
	if err := validate(staged); err != nil {
		return err
	}
	return replaceGeoPath(staged, path)
}

func writeSyncedTemp(path string, data []byte) (string, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", err
	}
	file, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".*.tmp")
	if err != nil {
		return "", err
	}
	_, err = file.Write(data)
	if err == nil {
		err = file.Chmod(0o644)
	}
	if err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		_ = os.Remove(file.Name())
		return "", err
	}
	return file.Name(), nil
}

func pendingGeoPath(path string) string {
	return path + ".pending"
}

func geoFileInUse(path string) string {
	if fileExists(pendingGeoPath(path)) {
		return pendingGeoPath(path)
	}
	return path
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func installPendingGeoFile(path string) error {
	pending := pendingGeoPath(path)
	if !fileExists(pending) {
		return nil
	}
	return replaceGeoPath(pending, path)
}

func installPendingGeoFiles() {
	for _, path := range []string{constant.Path.MMDB(), constant.Path.ASN()} {
		if err := installPendingGeoFile(path); err != nil {
			log.Warnln("[GEO] can't install %s: %v", filepath.Base(path), err)
		}
	}
}

// mihomo's updaters read these links without a lock, so an unchanged one is never rewritten.
func setGeoResourceUrl(geoType string, link string) {
	resource, exist := geoResources[strings.ToUpper(geoType)]
	if !exist {
		log.Warnln("geox-url: unknown geo resource %q", geoType)
		return
	}
	if link != "" && link != resource.url() {
		resource.setUrl(link)
	}
}

func claimGeoUpdate(geoType string) bool {
	return claimUpdate(geoUpdateScope + geoType)
}

func releaseGeoUpdate(geoType string) {
	releaseUpdate(geoUpdateScope + geoType)
}

func handleUpdateGeoData(geoType string) error {
	resource, exist := geoResources[geoType]
	if !exist {
		logError("updateGeoData: unknown geo resource %q", geoType)
		return fmt.Errorf("unknown geo resource: %s", geoType)
	}
	if !claimGeoUpdate(geoType) {
		return fmt.Errorf("geo update already in progress: %s", geoType)
	}
	safeGo("updateGeoData("+geoType+")", func() {
		defer releaseGeoUpdate(geoType)
		runGeoUpdate(geoType, resource)
	})
	return nil
}

// mihomo's updater returns nil for a download that matched the file it had,
// so whether the file changed is what tells an update from a skip.
func runGeoUpdate(geoType string, resource geoResource) {
	sendMessage(GeoUpdateMessage, GeoUpdateStatus{Type: geoType, Updating: true})
	before := resource.stamp()
	err := resource.update()
	if err != nil {
		logError("updateGeoData(%s) error: %v", geoType, err)
	}
	onGeoUpdate(geoType, false, err == nil && resource.stamp() == before, err)
}

type fileStampValue struct {
	size    int64
	modTime time.Time
}

func (resource geoResource) stamp() fileStampValue {
	if resource.path == nil {
		return fileStampValue{}
	}
	info, err := os.Stat(geoFileInUse(resource.path()))
	if err != nil {
		return fileStampValue{}
	}
	return fileStampValue{size: info.Size(), modTime: info.ModTime()}
}

func onGeoUpdate(geoType string, updating bool, skipped bool, updateErr error) {
	if updating {
		claimUpdateAs(geoUpdateScope+geoType, true)
	} else {
		releaseHookUpdate(geoUpdateScope + geoType)
		scheduleReclaimOwnership()
		if !skipped && updateErr == nil {
			changeRoute(routeMoved)
		}
	}
	status := GeoUpdateStatus{Type: geoType, Updating: updating, Skipped: skipped}
	if updateErr != nil {
		status.Error = updateErr.Error()
	}
	sendMessage(GeoUpdateMessage, status)
}

var (
	registerGeoUpdater = startGeoUpdater
	stopGeoUpdater     = stopGeoUpdaterRun
)

// mihomo starts its own geo updater only in its binary; the library leaves
// it to the host, which wants to stop it with the core and hear how each
// database fared.
var geoUpdaterRun struct {
	sync.Mutex
	cancel context.CancelFunc
}

func startGeoUpdater() {
	interval := updater.GeoUpdateInterval()
	if interval <= 0 {
		log.Warnln("[GEO] invalid update interval: %d", interval)
		return
	}
	stopGeoUpdaterRun()
	ctx, cancel := context.WithCancel(context.Background())
	geoUpdaterRun.Lock()
	geoUpdaterRun.cancel = cancel
	geoUpdaterRun.Unlock()
	go runGeoUpdater(ctx, time.Duration(interval)*time.Hour)
}

func stopGeoUpdaterRun() {
	geoUpdaterRun.Lock()
	defer geoUpdaterRun.Unlock()
	if geoUpdaterRun.cancel != nil {
		geoUpdaterRun.cancel()
		geoUpdaterRun.cancel = nil
	}
}

func runGeoUpdater(ctx context.Context, interval time.Duration) {
	first := interval - time.Since(lastGeoUpdateTime())
	if first < 0 {
		first = 0
	}
	timer := time.NewTimer(first)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			updateGeoResources()
			timer.Reset(interval)
		}
	}
}

func lastGeoUpdateTime() time.Time {
	for _, path := range []string{
		constant.Path.GeoIP(), constant.Path.MMDB(), constant.Path.ASN(), constant.Path.GeoSite(),
	} {
		if info, err := os.Stat(geoFileInUse(path)); err == nil {
			return info.ModTime()
		}
	}
	return time.Time{}
}

func enabledGeoResources() []string {
	var names []string
	if geodata.GeoIpEnable() {
		if geodata.GeodataMode() {
			names = append(names, "GEOIP")
		} else {
			names = append(names, "MMDB")
		}
	}
	if geodata.ASNEnable() {
		names = append(names, "ASN")
	}
	if geodata.GeoSiteEnable() {
		names = append(names, "GEOSITE")
	}
	return names
}

// A resource a manual update holds is left to it.
func updateGeoResources() {
	for _, name := range enabledGeoResources() {
		if !claimUpdateAs(geoUpdateScope+name, true) {
			continue
		}
		runGeoUpdate(name, geoResources[name])
	}
}

func syncGeoUpdater(autoUpdate *bool, interval *int) {
	changed := false
	if autoUpdate != nil && *autoUpdate != updater.GeoAutoUpdate() {
		updater.SetGeoAutoUpdate(*autoUpdate)
		changed = true
	}
	if interval != nil && *interval != updater.GeoUpdateInterval() {
		updater.SetGeoUpdateInterval(*interval)
		changed = true
	}
	if changed {
		reconcileGeoUpdater()
	}
}

func reconcileGeoUpdater() {
	if updater.GeoAutoUpdate() {
		registerGeoUpdater()
		return
	}
	stopGeoUpdater()
}
