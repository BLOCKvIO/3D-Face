package io.blockv.faces

import android.annotation.TargetApi
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.webkit.*
import io.blockv.common.model.Face
import io.blockv.common.model.Resource
import io.blockv.common.model.Vatom
import io.blockv.face.client.FaceBridge
import io.blockv.face.client.FaceView
import io.blockv.face.client.ViewFactory
import org.json.JSONArray
import org.json.JSONObject

class Face3D(vatom: Vatom, face: Face, bridge: FaceBridge) : FaceView(vatom, face, bridge) {

    // Static functions
    companion object {

        /** Factory which creates instances of this face as needed */
        val factory = object : ViewFactory {

            /** The display URL for our face */
            override val displayUrl = "native://generic-3d"

            /** Called when the VatomView wants to create an instance of our face */
            override fun emit(vatom: Vatom, face: Face, bridge: FaceBridge): FaceView {
                return Face3D(vatom, face, bridge)
            }

        }

    }

    /** The web view which renders our content */
    private var webView: WebView? = null

    /** Reference to the main thread */
    private val mainThread = Handler(Looper.getMainLooper())

    /** True if the web view is currently on the screen */
    private var isOnScreen = false

    /** True if the web view has loaded */
    private var isWebViewLoaded = false

    /** Called by VatomView to create and return our UI views */
    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup): View {

        // Create view
        WebView.setWebContentsDebuggingEnabled(true)
        webView = WebView(inflater.context)
        webView?.setBackgroundColor(Color.TRANSPARENT)
        webView?.settings?.javaScriptEnabled = true
        webView?.settings?.allowFileAccessFromFileURLs = true
        webView?.settings?.allowUniversalAccessFromFileURLs = true

        webView?.webViewClient = object : WebViewClient() {

            override fun shouldInterceptRequest(
                view: WebView?,
                url: String?
            ): WebResourceResponse? {
                if (url != null) {
                    return interceptRequest(Uri.parse(url)) ?: super.shouldInterceptRequest(
                        view,
                        url
                    )
                }
                return null
            }

            @TargetApi(Build.VERSION_CODES.LOLLIPOP)
            override fun shouldInterceptRequest(
                view: WebView?,
                request: WebResourceRequest?
            ): WebResourceResponse? {
                if (request != null) {
                    val original = request.url
                    return interceptRequest(original) ?: super.shouldInterceptRequest(view, request)
                }
                return null
            }

            fun interceptRequest(original: Uri): WebResourceResponse? {
                val clearedUrl = original
                    .buildUpon()
                    .clearQuery()
                    .build()
                    .toString()
                // Override downloads for .glb and .v3d files
                if (clearedUrl.endsWith(".glb", true) || clearedUrl.endsWith(".v3d", true)) {
                    try {
                        //Remove encoding params
                        val encoded = Uri.parse(
                            bridge.resourceManager.resourceEncoder.encodeUrl(clearedUrl)
                        )
                        val params = encoded.queryParameterNames
                        val out = original
                            .buildUpon()
                            .clearQuery()
                        for (param in original.queryParameterNames) {
                            if (!params.contains(param)) {
                                out.appendQueryParameter(
                                    param,
                                    original.getQueryParameter(param)
                                )
                            }
                        }

                        return WebResourceResponse(
                            "application/octet-stream",
                            null,
                            // Download asset using resource manager
                            bridge.resourceManager.getInputStream(
                                Resource(
                                    "scene",
                                    "",
                                    out.build().toString()
                                )
                            ).blockingGet()
                        )

                    } catch (e: Exception) {
                    }
                }
                return null
            }

        }

        // Allow the web app to access certain functions on this class instance via the `nativeFace` global property
        webView?.addJavascriptInterface(this, "nativeBridge")

        // Attach a listener to know when the web view is on-screen
        webView?.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {

            override fun onViewAttachedToWindow(p0: View?) {
                isOnScreen = true
                loadIfNeeded()
            }

            override fun onViewDetachedFromWindow(p0: View?) {
                isOnScreen = false
            }

        })

        // Done
        return webView!!

    }

    /** Called by VatomView when resources should start loading */
    override fun onLoad(handler: LoadHandler) {

        // Start loading if on screen
        loadIfNeeded()

        // Done
        handler.onComplete()

    }

    /** Called once the web view is on-screen, and VatomView has called our onLoad() */
    fun loadIfNeeded() {

        // Ensure web view is on screen, and has not loaded yet
        if (!isOnScreen || isWebViewLoaded) return
        isWebViewLoaded = true

        // Start loading the web app
        webView?.loadUrl("file:///android_asset/face3drenderer/index.html");

    }

    override fun onVatomChanged(vatom: Vatom) {

        // Get new vatom payload
        val payload = getVatomPayload(vatom).toString(0)

        // Go to main thread
        mainThread.post {

            // Inform web app of the change
            webView?.evaluateJavascript("vatomStateChanged($payload)", null)

        }

    }

    /** Returns the vAtom payload */
    private fun getVatomPayload(vatom: Vatom): JSONObject {

        // Create vatom payload
        // HACK: We don't have access to the actual raw vatom payload. Recreate it as best we can with the fields
        // they're most likely to use.
        val vatomPayload = JSONObject()
        vatomPayload.put("id", vatom.id)
        vatomPayload.put("private", vatom.private ?: JSONObject())

        val vatomSection = JSONObject()
        vatomSection.put("cloning_score", vatom.property.cloningScore)
        vatomSection.put("in_contract_with", vatom.property.inContractWith)
        vatomSection.put("num_direct_clones", vatom.property.numDirectClones)
        vatomSection.put("parent_id", vatom.property.parentId)
        vatomSection.put("title", vatom.property.title)
        vatomSection.put("template", vatom.property.templateId)
        vatomSection.put("template_variation", vatom.property.templateVariationId)
        vatomPayload.put("vAtom::vAtomType", vatomSection)

        // Add resource array
        val resourceArray = JSONArray()
        vatomSection.put("resources", resourceArray)
        for (res in vatom.property.resources) {

            // Create entry
            val r = JSONObject()
            r.put("name", res.name)
            r.put("resourceType", res.type)

            val rr = JSONObject()
            r.put("value", rr)
            rr.put("value", res.url)

            // Add it
            resourceArray.put(r)

        }

        // Done
        return vatomPayload

    }

    /** Called by the web app. Returns the renderer info */
    @JavascriptInterface
    fun getRendererInfo(): String {

        // Create object
        val info = JSONObject()

        // Add vatom payload
        info.put("vatomPayload", getVatomPayload(this.vatom))

        // Add face payload. HACK: Reconstruct as best we can from the info in the model
        val facePayload = JSONObject()
        info.put("facePayload", facePayload)
        facePayload.put("id", face.id)

        val faceProps = JSONObject()
        facePayload.put("properties", faceProps)
        faceProps.put("display_url", face.property.displayUrl)
        faceProps.put("config", face.property.config)

        val faceConstraints = JSONObject()
        faceProps.put("constraints", faceConstraints)
        faceConstraints.put("platform", face.property.platform)
        faceConstraints.put("view_mode", face.property.viewMode)

        // Done
        return info.toString(0)

    }

    /** Called by the web app. Signs a resource URL. */
    @JavascriptInterface
    fun signURL(id: String, url: String) {

        // Catch errors
        try {

            // Sign the URL
            val signedURL = bridge.resourceManager.resourceEncoder.encodeUrl(url)

            // Go to main thread
            mainThread.post {

                // Return the signed URL
                webView?.evaluateJavascript("signURLComplete(\"$id\", \"$signedURL\")", null)

            }

        } catch (err: Exception) {

            // Pass error back
            err.printStackTrace()
            val msg = err.localizedMessage.replace("\"", "\\\"")

            // Go to main thread and post the response
            mainThread.post {
                webView?.evaluateJavascript("signURLFailed(\"$id\", \"$msg\")", null)
            }

        }

    }

}