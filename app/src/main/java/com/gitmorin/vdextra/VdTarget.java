package com.gitmorin.vdextra;

import lombok.experimental.UtilityClass;

@UtilityClass
class VdTarget {
    final String[] PACKAGES = {"VirtualDesktop.Quest", "VirtualDesktop.Android"};

    boolean matches(String packageName) {
        for (String p : PACKAGES) if (p.equals(packageName)) return true;
        return false;
    }
}
