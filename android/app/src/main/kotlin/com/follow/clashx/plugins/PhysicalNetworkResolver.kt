// SPDX-FileCopyrightText: 2026 Ivan Zorin <creator@localzet.com>
// SPDX-License-Identifier: GPL-3.0-or-later

package com.follow.clashx.plugins

internal fun <N> selectLegacyPhysicalNetwork(
    eligible: List<N>,
    active: N?,
    current: N?,
    priority: (N) -> Int,
): N? {
    if (active != null && active in eligible) return active
    val bestPriority = eligible.minOfOrNull(priority) ?: return null
    return current?.takeIf { it in eligible && priority(it) == bestPriority }
        ?: eligible.firstOrNull { priority(it) == bestPriority }
}

internal fun <N, A> resolveOnPhysicalNetwork(
    selectNetwork: () -> N?,
    lookup: (N) -> List<A>,
): List<A> {
    val network = selectNetwork() ?: return emptyList()
    val addresses = runCatching { lookup(network) }.getOrNull() ?: return emptyList()
    return if (selectNetwork() == network) addresses else emptyList()
}
