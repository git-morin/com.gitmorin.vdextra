package com.gitmorin.vdextra

internal object VdTarget {
    val PACKAGES = arrayOf("VirtualDesktop.Quest", "VirtualDesktop.Android")

    fun matches(packageName: String?) = PACKAGES.any { it == packageName }
}
