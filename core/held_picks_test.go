package core

import (
	"maps"
	"sync"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
)

const heldPickTestURL = "https://probe.example.test/generate_204"

type heldPickTestProxy struct {
	constant.Proxy
	mu        sync.RWMutex
	alive     bool
	delays    map[string]constant.ProxyState
	lastDelay uint16
}

func newHeldPickTestProxy(name string, alive bool, delay uint16, tested bool) *heldPickTestProxy {
	proxy := &heldPickTestProxy{
		Proxy:     namedProxy(name),
		alive:     alive,
		lastDelay: delay,
		delays:    map[string]constant.ProxyState{},
	}
	if tested {
		proxy.record(heldPickTestURL, alive, delay)
	}
	return proxy
}

func (p *heldPickTestProxy) AliveForTestUrl(string) bool {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.alive
}

func (p *heldPickTestProxy) ExtraDelayHistories() map[string]constant.ProxyState {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return maps.Clone(p.delays)
}

func (p *heldPickTestProxy) LastDelayForTestUrl(url string) uint16 {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if state := p.delays[url]; len(state.History) > 0 {
		return state.History[len(state.History)-1].Delay
	}
	return p.lastDelay
}

func (p *heldPickTestProxy) record(url string, alive bool, delay uint16) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.alive = alive
	p.lastDelay = delay
	p.delays[url] = constant.ProxyState{
		Alive: alive,
		History: []constant.DelayHistory{{
			Time:  time.Now(),
			Delay: delay,
		}},
	}
}

func (p *heldPickTestProxy) probeAfterGate(
	url string,
	alive bool,
	delay uint16,
	gate <-chan struct{},
	started chan<- struct{},
	done chan<- struct{},
) {
	go func() {
		close(started)
		<-gate
		p.record(url, alive, delay)
		close(done)
	}()
}

func heldAutoGroup(t *testing.T, kind, name, testURL string, members ...constant.Proxy) constant.Proxy {
	t.Helper()
	health := provider.NewHealthCheck(members, "", 0, 0, true, nil)
	provider, err := provider.NewCompatibleProvider(name+"-provider", members, health)
	if err != nil {
		t.Fatalf("NewCompatibleProvider: %v", err)
	}
	providers := []cp.ProxyProvider{provider}
	common := outboundgroup.GroupCommonOption{Name: name, URL: testURL}
	var group outboundgroup.ProxyGroup
	switch kind {
	case "url-test":
		group, err = outboundgroup.NewURLTest(
			common,
			outboundgroup.URLTestOption{},
			namedProxy(name+"-fallback"),
			providers,
		)
	case "fallback":
		group, err = outboundgroup.NewFallback(
			common,
			outboundgroup.FallbackOption{},
			namedProxy(name+"-fallback"),
			providers,
		)
	default:
		t.Fatalf("unsupported automatic group type %q", kind)
	}
	if err != nil {
		t.Fatalf("New%s: %v", kind, err)
	}
	return adapter.NewProxy(group)
}

func beginHeldPickTest(t *testing.T, proxies map[string]constant.Proxy) {
	t.Helper()
	previousProxies, previousProviders := tunnel.Proxies(), tunnel.Providers()

	selectMu.Lock()
	previousInterval := heldCheckInterval
	heldCheckInterval = 10 * time.Millisecond
	previousHeld := maps.Clone(heldPicks)
	previousRevisions := maps.Clone(pickRevisions)
	clear(heldPicks)
	clear(pickRevisions)
	selectMu.Unlock()

	tunnel.UpdateProxies(proxies, nil)
	invalidateAllProxies()
	t.Cleanup(func() {
		selectMu.Lock()
		clear(heldPicks)
		if heldWatchCancel != nil {
			heldWatchCancel()
			heldWatchCancel = nil
			heldWatchVersion++
			heldWatching = false
		}
		selectMu.Unlock()
		waitForHeldWatcher(t)

		selectMu.Lock()
		clear(heldPicks)
		clear(pickRevisions)
		maps.Copy(heldPicks, previousHeld)
		maps.Copy(pickRevisions, previousRevisions)
		heldCheckInterval = previousInterval
		selectMu.Unlock()
		tunnel.UpdateProxies(previousProxies, previousProviders)
		invalidateAllProxies()
	})
}

func waitForHeldWatcher(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for {
		selectMu.Lock()
		watching := heldWatching
		selectMu.Unlock()
		if !watching {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("held-pick watcher did not stop")
		}
		time.Sleep(time.Millisecond)
	}
}

func checkedHeldGroup(t *testing.T, kind string) (constant.Proxy, *heldPickTestProxy, *heldPickTestProxy) {
	t.Helper()
	first, second := newHeldPickTestProxy("dead", true, 250, true), newHeldPickTestProxy("live", true, 20, true)
	if kind == "fallback" {
		first = newHeldPickTestProxy("dead", false, 0, true)
	}
	group := heldAutoGroup(t, kind, "Auto", heldPickTestURL, first, second)
	return group, first, second
}

func TestURLTestPickStaysHeldUntilFreshProbesComplete(t *testing.T) {
	oldGroup, _, _ := checkedHeldGroup(t, "url-test")
	beginHeldPickTest(t, map[string]constant.Proxy{"Auto": oldGroup})

	carried := carriedPicks()
	if got := carried["Auto"].proxy; got != "live" {
		t.Fatalf("carried pick = %q, want the last checked fastest node", got)
	}

	newFirst := newHeldPickTestProxy("dead", true, 0, false)
	newLive := newHeldPickTestProxy("live", true, 0, false)
	newGroup := heldAutoGroup(t, "url-test", "Auto", heldPickTestURL, newFirst, newLive)
	tunnel.UpdateProxies(map[string]constant.Proxy{"Auto": newGroup}, nil)
	invalidateAllProxies()
	holdPicks(map[string]constant.Proxy{"Auto": newGroup}, carried, nil)

	if got := groupNow(t, newGroup); got != "live" {
		t.Fatalf("reloaded group picked %q while probes are pending, want live", got)
	}
	if fixed := groupFixed(t, newGroup); fixed != "live" {
		t.Fatalf("core hold = %q, want live", fixed)
	}

	newFirst.record(heldPickTestURL, true, 200)
	gate, started, done := make(chan struct{}), make(chan struct{}), make(chan struct{})
	newLive.probeAfterGate(heldPickTestURL, true, 15, gate, started, done)
	<-started
	if releaseTestedPicks() != 1 {
		t.Fatal("hold ended before the held node received a fresh probe")
	}
	close(gate)
	<-done
	if releaseTestedPicks() != 0 {
		t.Fatal("hold remained after all fresh probes completed")
	}
	if fixed := groupFixed(t, newGroup); fixed != "" {
		t.Fatalf("group remained pinned to %q after fresh probes", fixed)
	}
}

func TestCarryRequiresACheckedLiveNodeAndIgnoresSelectors(t *testing.T) {
	untested := heldAutoGroup(
		t,
		"url-test",
		"Auto",
		heldPickTestURL,
		newHeldPickTestProxy("node-a", true, 0, false),
		newHeldPickTestProxy("node-b", true, 0, false),
	)
	manual := selectorGroup(t, "Manual", "node-a", "node-b")
	beginHeldPickTest(t, map[string]constant.Proxy{"Auto": untested, "Manual": manual})

	if carried := carriedPicks(); len(carried) != 0 {
		t.Fatalf("carried picks = %v, want none without a completed health check", carried)
	}
}

func TestFallbackHoldWaitsForChecksOfEarlierMembers(t *testing.T) {
	oldGroup, _, _ := checkedHeldGroup(t, "fallback")
	beginHeldPickTest(t, map[string]constant.Proxy{"Auto": oldGroup})
	carried := carriedPicks()
	if got := carried["Auto"].proxy; got != "live" {
		t.Fatalf("carried pick = %q, want live", got)
	}

	first := newHeldPickTestProxy("dead", true, 0, false)
	live := newHeldPickTestProxy("live", true, 0, false)
	newGroup := heldAutoGroup(t, "fallback", "Auto", heldPickTestURL, first, live)
	tunnel.UpdateProxies(map[string]constant.Proxy{"Auto": newGroup}, nil)
	invalidateAllProxies()
	holdPicks(map[string]constant.Proxy{"Auto": newGroup}, carried, nil)

	live.record(heldPickTestURL, true, 12)
	gate, started, done := make(chan struct{}), make(chan struct{}), make(chan struct{})
	first.probeAfterGate(heldPickTestURL, false, 0, gate, started, done)
	<-started
	if releaseTestedPicks() != 1 {
		t.Fatal("fallback hold ended while the earlier member's probe was gated")
	}
	close(gate)
	<-done
	if releaseTestedPicks() != 0 {
		t.Fatal("fallback hold remained after the earlier member was checked")
	}
	if got := groupNow(t, newGroup); got != "live" {
		t.Fatalf("fallback resumed on %q after probing, want live", got)
	}
}

func TestHoldRejectsChangedTestURLGroupAndNode(t *testing.T) {
	t.Run("test URL changed", func(t *testing.T) {
		oldGroup, _, _ := checkedHeldGroup(t, "url-test")
		beginHeldPickTest(t, map[string]constant.Proxy{"Auto": oldGroup})
		carried := carriedPicks()
		newGroup := heldAutoGroup(t, "url-test", "Auto", "https://other.example/", newHeldPickTestProxy("dead", true, 1, false), newHeldPickTestProxy("live", true, 2, false))
		holdPicks(map[string]constant.Proxy{"Auto": newGroup}, carried, nil)
		if len(heldGroups()) != 0 {
			t.Fatal("held the previous pick after its test URL changed")
		}
	})

	t.Run("group removed", func(t *testing.T) {
		oldGroup, _, _ := checkedHeldGroup(t, "url-test")
		beginHeldPickTest(t, map[string]constant.Proxy{"Auto": oldGroup})
		carried := carriedPicks()
		holdPicks(nil, carried, nil)
		if len(heldGroups()) != 0 {
			t.Fatal("held a group that the new profile removed")
		}
	})

	t.Run("node removed", func(t *testing.T) {
		oldGroup, _, _ := checkedHeldGroup(t, "url-test")
		beginHeldPickTest(t, map[string]constant.Proxy{"Auto": oldGroup})
		carried := carriedPicks()
		newGroup := heldAutoGroup(t, "url-test", "Auto", heldPickTestURL, newHeldPickTestProxy("dead", true, 1, false))
		holdPicks(map[string]constant.Proxy{"Auto": newGroup}, carried, nil)
		if len(heldGroups()) != 0 {
			t.Fatal("held a node that the new profile removed")
		}
	})
}

func TestNewApplyCancelsWatcherAndDropsRemovedGroupReferences(t *testing.T) {
	oldGroup, _, _ := checkedHeldGroup(t, "url-test")
	beginHeldPickTest(t, map[string]constant.Proxy{"Auto": oldGroup})
	carried := carriedPicks()
	newGroup := heldAutoGroup(t, "url-test", "Auto", heldPickTestURL, newHeldPickTestProxy("dead", true, 1, false), newHeldPickTestProxy("live", true, 2, false))
	newProxies := map[string]constant.Proxy{"Auto": newGroup}
	holdPicks(newProxies, carried, nil)
	if heldGroups()["Auto"] != newGroup {
		t.Fatal("hold retained the old group after an apply")
	}

	holdPicks(nil, nil, nil)
	if len(heldGroups()) != 0 {
		t.Fatal("removed group remained reachable through a stale hold")
	}
	selectMu.Lock()
	watching, cancel := heldWatching, heldWatchCancel
	selectMu.Unlock()
	if watching || cancel != nil {
		t.Fatal("watcher remained active after the new profile removed all held groups")
	}
}

func TestHoldDoesNotOverrideExplicitOrConcurrentUserSelection(t *testing.T) {
	t.Run("manual unpin before pick capture", func(t *testing.T) {
		oldGroup, _, _ := checkedHeldGroup(t, "url-test")
		beginHeldPickTest(t, map[string]constant.Proxy{"Auto": oldGroup})
		revisionsAtApplyStart := pickRevisionSnapshot()
		if result := handleChangeProxy(&ChangeProxyParams{GroupName: "Auto", ProxyName: ""}); result.Message != "" {
			t.Fatalf("manual unpin: %s", result.Message)
		}
		carried := carriedPicksSince(revisionsAtApplyStart)
		newGroup := heldAutoGroup(t, "url-test", "Auto", heldPickTestURL, newHeldPickTestProxy("dead", true, 1, false), newHeldPickTestProxy("live", true, 2, false))
		holdPicks(map[string]constant.Proxy{"Auto": newGroup}, carried, nil)
		if len(heldGroups()) != 0 {
			t.Fatal("apply held an automatically selected node after a concurrent unpin")
		}
	})

	t.Run("configured pin", func(t *testing.T) {
		oldGroup, _, _ := checkedHeldGroup(t, "url-test")
		beginHeldPickTest(t, map[string]constant.Proxy{"Auto": oldGroup})
		carried := carriedPicks()
		newGroup := heldAutoGroup(t, "url-test", "Auto", heldPickTestURL, newHeldPickTestProxy("dead", true, 1, false), newHeldPickTestProxy("live", true, 2, false))
		newProxies := map[string]constant.Proxy{"Auto": newGroup}
		patchSelectGroup(newProxies, map[string]string{"Auto": "dead"})
		holdPicks(newProxies, carried, map[string]string{"Auto": "dead"})
		if fixed := groupFixed(t, newGroup); fixed != "dead" {
			t.Fatalf("configured pin = %q, want dead", fixed)
		}
		if len(heldGroups()) != 0 {
			t.Fatal("core hold overrode an explicit configured pin")
		}
	})

	t.Run("manual selection during apply", func(t *testing.T) {
		oldGroup, _, _ := checkedHeldGroup(t, "url-test")
		beginHeldPickTest(t, map[string]constant.Proxy{"Auto": oldGroup})
		carried := carriedPicks()
		newGroup := heldAutoGroup(t, "url-test", "Auto", heldPickTestURL, newHeldPickTestProxy("dead", true, 1, false), newHeldPickTestProxy("live", true, 2, false))
		tunnel.UpdateProxies(map[string]constant.Proxy{"Auto": newGroup}, nil)
		invalidateAllProxies()
		if result := handleChangeProxy(&ChangeProxyParams{GroupName: "Auto", ProxyName: "dead"}); result.Message != "" {
			t.Fatalf("manual selection: %s", result.Message)
		}
		holdPicks(map[string]constant.Proxy{"Auto": newGroup}, carried, nil)
		if fixed := groupFixed(t, newGroup); fixed != "dead" {
			t.Fatalf("manual selection = %q, want dead", fixed)
		}
		if len(heldGroups()) != 0 {
			t.Fatal("apply held the group over a concurrent manual selection")
		}
	})

	t.Run("refused selection preserves the hold", func(t *testing.T) {
		oldGroup, _, _ := checkedHeldGroup(t, "url-test")
		beginHeldPickTest(t, map[string]constant.Proxy{"Auto": oldGroup})
		carried := carriedPicks()
		newGroup := heldAutoGroup(t, "url-test", "Auto", heldPickTestURL, newHeldPickTestProxy("dead", true, 1, false), newHeldPickTestProxy("live", true, 2, false))
		newProxies := map[string]constant.Proxy{"Auto": newGroup}
		tunnel.UpdateProxies(newProxies, nil)
		invalidateAllProxies()
		holdPicks(newProxies, carried, nil)

		if result := handleChangeProxy(&ChangeProxyParams{GroupName: "Auto", ProxyName: "missing"}); result.Message == "" {
			t.Fatal("accepted a selection the group does not have")
		}
		if heldGroups()["Auto"] != newGroup || groupFixed(t, newGroup) != "live" {
			t.Fatal("a refused selection cancelled the held pick")
		}
	})
}

func TestCoreHeldPickIsNotReportedAsAUserPin(t *testing.T) {
	oldGroup, _, _ := checkedHeldGroup(t, "url-test")
	beginHeldPickTest(t, map[string]constant.Proxy{"Auto": oldGroup})
	carried := carriedPicks()
	newGroup := heldAutoGroup(t, "url-test", "Auto", heldPickTestURL, newHeldPickTestProxy("dead", true, 1, false), newHeldPickTestProxy("live", true, 2, false))
	tunnel.UpdateProxies(map[string]constant.Proxy{"Auto": newGroup}, nil)
	invalidateAllProxies()
	holdPicks(map[string]constant.Proxy{"Auto": newGroup}, carried, nil)

	view, ok := handleGetProxies().Proxies["Auto"].(map[string]any)
	if !ok {
		t.Fatal("automatic group has no serialized view")
	}
	if fixed, _ := view["fixed"].(string); fixed != "" {
		t.Fatalf("UI pin = %q, want the core hold hidden", fixed)
	}
}

func TestProxyViewDoesNotHideAConcurrentManualPin(t *testing.T) {
	oldGroup, _, _ := checkedHeldGroup(t, "url-test")
	beginHeldPickTest(t, map[string]constant.Proxy{"Auto": oldGroup})
	carried := carriedPicks()
	newGroup := heldAutoGroup(t, "url-test", "Auto", heldPickTestURL, newHeldPickTestProxy("dead", true, 1, false), newHeldPickTestProxy("live", true, 2, false))
	proxies := map[string]constant.Proxy{"Auto": newGroup}
	tunnel.UpdateProxies(proxies, nil)
	invalidateAllProxies()
	holdPicks(proxies, carried, nil)

	enteredView, finishView := make(chan struct{}), make(chan struct{})
	viewsReady := make(chan map[string]any, 1)
	go func() {
		viewsReady <- proxyViews(proxies, func(proxy constant.Proxy) any {
			close(enteredView)
			<-finishView
			return proxyView(proxy)
		})
	}()
	<-enteredView

	selectionDone := make(chan *ChangeProxyResult, 1)
	go func() {
		selectionDone <- handleChangeProxy(&ChangeProxyParams{GroupName: "Auto", ProxyName: "dead"})
	}()
	if selectMu.TryLock() {
		selectMu.Unlock()
		t.Fatal("proxy view released selectMu before applying the internal hold mask")
	}

	close(finishView)
	views := <-viewsReady
	if result := <-selectionDone; result.Message != "" {
		t.Fatalf("manual selection: %s", result.Message)
	}
	groupView, ok := views["Auto"].(map[string]any)
	if !ok {
		t.Fatal("automatic group has no serialized snapshot")
	}
	if fixed, _ := groupView["fixed"].(string); fixed != "" {
		t.Fatalf("snapshot exposed the core hold as a user pin: %q", fixed)
	}
	view, ok := handleGetProxies().Proxies["Auto"].(map[string]any)
	if !ok {
		t.Fatal("automatic group has no serialized view")
	}
	if fixed, _ := view["fixed"].(string); fixed != "dead" {
		t.Fatalf("manual pin was hidden by a stale hold snapshot: %q", fixed)
	}
}

func groupFixed(t *testing.T, proxy constant.Proxy) string {
	t.Helper()
	group, _, fixed, ok := autoGroupOf(proxy)
	if !ok || group == nil {
		t.Fatalf("%q is not an automatic group", proxy.Name())
	}
	return fixed
}
