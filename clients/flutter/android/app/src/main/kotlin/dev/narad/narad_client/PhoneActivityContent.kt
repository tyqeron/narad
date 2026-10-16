package dev.narad.narad_client

import android.app.Activity
import android.view.View
import android.widget.FrameLayout

/** Keep native phone controls inside the system bars, including enforced edge-to-edge. */
@Suppress("DEPRECATION")
fun Activity.setPhoneContent(content: View) {
    val frame = FrameLayout(this)
    frame.addView(content)
    frame.setOnApplyWindowInsetsListener { view, insets ->
        view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop,
            insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
        insets
    }
    setContentView(frame)
    frame.requestApplyInsets()
}
