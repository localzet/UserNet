package core

import (
	"context"
	"encoding/json"
	"maps"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/constant"
)

type heldPick struct {
	group    constant.Proxy
	proxy    string
	testURL  string
	revision uint64
}

var (
	heldPicks         = map[string]heldPick{}
	heldWatching      bool
	heldWatchCancel   context.CancelFunc
	heldWatchVersion  uint64
	pickRevisions     = map[string]uint64{}
	heldCheckInterval = time.Second
)

func autoGroupOf(proxy constant.Proxy) (group pickableGroup, testURL, fixed string, ok bool) {
	adapterProxy, isAdapter := proxy.(*adapter.Proxy)
	if !isAdapter {
		return nil, "", "", false
	}
	switch adapterProxy.ProxyAdapter.(type) {
	case *outboundgroup.URLTest, *outboundgroup.Fallback:
	default:
		return nil, "", "", false
	}
	group, ok = adapterProxy.ProxyAdapter.(pickableGroup)
	if !ok {
		return nil, "", "", false
	}
	data, err := group.MarshalJSON()
	if err != nil {
		return nil, "", "", false
	}
	var view struct {
		TestURL string `json:"testUrl"`
		Fixed   string `json:"fixed"`
	}
	if json.Unmarshal(data, &view) != nil {
		return nil, "", "", false
	}
	return group, view.TestURL, view.Fixed, true
}

func memberNamed(group pickableGroup, name string) constant.Proxy {
	for _, member := range group.Proxies() {
		if member.Name() == name {
			return member
		}
	}
	return nil
}

func testedFor(member constant.Proxy, testURL string) bool {
	if member == nil {
		return false
	}
	state, ok := member.ExtraDelayHistories()[testURL]
	return ok && len(state.History) > 0
}

func pickRevisionSnapshot() map[string]uint64 {
	selectMu.Lock()
	defer selectMu.Unlock()
	return maps.Clone(pickRevisions)
}

func carriedPicks() map[string]heldPick {
	return carriedPicksSince(pickRevisionSnapshot())
}

func carriedPicksSince(revisions map[string]uint64) map[string]heldPick {
	selectMu.Lock()
	defer selectMu.Unlock()

	picks := map[string]heldPick{}
	for name, proxy := range allProxies() {
		revision := revisions[name]
		if pickRevisions[name] != revision {
			continue
		}
		group, testURL, fixed, ok := autoGroupOf(proxy)
		if !ok {
			continue
		}

		if held, isHeld := heldPicks[name]; isHeld && held.group == proxy && fixed == held.proxy {
			member := memberNamed(group, held.proxy)
			if testedFor(member, testURL) && member.AliveForTestUrl(testURL) {
				held.revision = revision
				picks[name] = held
			}
			continue
		}
		if fixed != "" {
			continue
		}

		now := group.Now()
		member := memberNamed(group, now)
		if testedFor(member, testURL) && member.AliveForTestUrl(testURL) {
			picks[name] = heldPick{proxy: now, testURL: testURL, revision: revision}
		}
	}
	return picks
}

func holdPicks(proxies map[string]constant.Proxy, carried map[string]heldPick, pinned map[string]string) {
	selectMu.Lock()
	defer selectMu.Unlock()

	heldWatchVersion++
	watchVersion := heldWatchVersion
	if heldWatchCancel != nil {
		heldWatchCancel()
		heldWatchCancel = nil
	}
	heldWatching = false
	clear(heldPicks)
	for name, pick := range carried {
		if pinned[name] != "" || pickRevisions[name] != pick.revision {
			continue
		}
		group, testURL, fixed, ok := autoGroupOf(proxies[name])
		if !ok || fixed != "" || testURL != pick.testURL || memberNamed(group, pick.proxy) == nil {
			continue
		}
		group.ForceSet(pick.proxy)
		pick.group = proxies[name]
		heldPicks[name] = pick
	}
	if len(heldPicks) > 0 {
		ctx, cancel := context.WithCancel(context.Background())
		heldWatchCancel = cancel
		heldWatching = true
		safeGo("watch held picks", func() { watchHeldPicks(ctx, watchVersion) })
	}
}

func watchHeldPicks(ctx context.Context, watchVersion uint64) {
	defer func() {
		selectMu.Lock()
		if heldWatchVersion == watchVersion {
			heldWatching = false
			heldWatchCancel = nil
		}
		selectMu.Unlock()
	}()

	for {
		timer := time.NewTimer(heldPickCheckInterval())
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
		if releaseTestedPicks() == 0 {
			return
		}
	}
}

func heldPickCheckInterval() time.Duration {
	selectMu.Lock()
	defer selectMu.Unlock()
	return heldCheckInterval
}

func checkedThrough(group pickableGroup, pick heldPick) bool {
	for _, member := range group.Proxies() {
		if !testedFor(member, pick.testURL) {
			return false
		}
		if member.Name() == pick.proxy {
			return true
		}
	}
	return false
}

func releaseTestedPicks() (held int) {
	selectMu.Lock()
	defer selectMu.Unlock()

	for name, pick := range heldPicks {
		proxy := lookupProxy(name)
		group, _, fixed, ok := autoGroupOf(proxy)
		switch {
		case !ok || proxy != pick.group || fixed != pick.proxy:
			delete(heldPicks, name)
		case memberNamed(group, pick.proxy) == nil || checkedThrough(group, pick):
			group.ForceSet("")
			delete(heldPicks, name)
		}
	}
	if len(heldPicks) == 0 {
		heldWatching = false
	}
	return len(heldPicks)
}

// selectMu is held.
func userPicked(group string) {
	delete(heldPicks, group)
	pickRevisions[group]++
}

func heldGroups() map[string]constant.Proxy {
	selectMu.Lock()
	defer selectMu.Unlock()

	groups := make(map[string]constant.Proxy, len(heldPicks))
	for name, pick := range heldPicks {
		groups[name] = pick.group
	}
	return groups
}
