package com.gitmorin.vdextra;

import lombok.experimental.UtilityClass;

/**
 * Virtual Desktop ships under different package names depending on distribution channel
 * (the Meta Quest Store build vs. the generic sideloaded Android build) - keep both in sync
 * with {@code META-INF/xposed/scope.list} and the manifest's {@code <queries>} block.
 */
@UtilityClass
class VdTarget {
    final String[] PACKAGES = {"VirtualDesktop.Quest", "VirtualDesktop.Android"};

    boolean matches(String packageName) {
        for (String p : PACKAGES) if (p.equals(packageName)) return true;
        return false;
    }
}
