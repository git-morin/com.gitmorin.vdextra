package com.gitmorin.vdextra

import org.json.JSONObject

internal object DictJson {

    fun count(json: String?): Int {
        if (json == null) return 0
        return try {
            var c = 0
            val keys = JSONObject(json).keys()
            while (keys.hasNext()) {
                keys.next()
                c++
            }
            c
        } catch (t: Throwable) {
            -1
        }
    }

    fun parseInto(json: String, out: MutableMap<String, String>) {
        try {
            val o = JSONObject(json)
            val keys = o.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                out[k] = o.optString(k, "")
            }
        } catch (ignored: Throwable) {
        }
    }
}
