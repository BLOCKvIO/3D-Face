//
//  Face3D.swift
//  Pods
//
//  Created by Josh Fox on 2018/10/23.
//

import Foundation
import BLOCKv
import FLAnimatedImage
import Nuke
import NVActivityIndicatorView
import WebKit
import GenericJSON

public class Face3D : FaceView, WKScriptMessageHandler, WKNavigationDelegate {
    
    /// The display URL for this face
    public static var displayURL : String { return "native://generic-3d" }
    
    /// True if the face has loaded and is ready to be displayed
    public var isLoaded: Bool = false
    
    // Views
    var imageView : FLAnimatedImageView!
    var errorView : UIButton!
    var error : Error?
    var loadingView : UIView!
    var webView : WKWebView?
    
    /*
     - Since this is in the cache directory, do I need to make provision for the system sweeping?
     - Defining and creating the resources directory should be a part of the face module. All the generic-3d face should
     do is create it's subdirectory.
     - The face_data directory should be create once (hopefully)
     
     WKWebView is only permitted access to a single directory. In order to pass local file urls to WKWebView at
     runtime, the pointed to directory must be writable. For this reason the caches directory is used.
     Copy contents of the bundles resource directory to the caches directory.
     
     face_data
     |- index.html
     |- main.js
     |- ...
     |- resources/
     */
    
    // temporary directory when both the web source files and the vatom resources are placed.
    let cacheDirectoryURL = try! FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    lazy var faceCacheDirectoryURL = cacheDirectoryURL.appendingPathComponent("face_data")
    
    public required init(vatom: VatomModel, faceModel: FaceModel) throws {
        try super.init(vatom: vatom, faceModel: faceModel)

        // create directories if needed
        try FileManager.default.createDirectory(at: faceCacheDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        // remove any existing generic-3d related files
        try FileManager.default.removeFiles(in: faceCacheDirectoryURL, occuringIn: Face3D.baseURL)
        // copy generic-3d files into cache directory
        try FileManager.default.copyContents(in: Face3D.baseURL, to: faceCacheDirectoryURL)
        
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    /// Called on startup
    public func load(completion: ((Error?) -> Void)?) {
        
        // Create image view
        imageView = FLAnimatedImageView()
        imageView.frame = self.bounds
        imageView.autoresizingMask = [ .flexibleWidth, .flexibleHeight ]
        imageView.contentMode = .scaleAspectFit
        self.addSubview(imageView)
        
        // Create error view
        errorView = UIButton(type: .detailDisclosure)
        errorView.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        errorView.isHidden = true
        self.addSubview(errorView)
        
        errorView.addTarget(self, action: #selector(onErrorButtonClick), for: .touchUpInside)
        
        // Create loading view
        loadingView = UIView()
        loadingView.frame = CGRect(x: 0, y: 0, width: 100, height: 40)
        loadingView.layer.cornerRadius = 4
        loadingView.clipsToBounds = true
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(loadingView)
        
        loadingView.widthAnchor.constraint(equalToConstant: 100).isActive = true
        loadingView.heightAnchor.constraint(equalToConstant: 40).isActive = true
        loadingView.bottomAnchor.constraint(equalTo: self.safeAreaLayoutGuide.bottomAnchor, constant: -64).isActive = true
        loadingView.centerXAnchor.constraint(equalTo: self.centerXAnchor).isActive = true
        
        // Add blur view
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .light))
        blur.frame = loadingView.bounds
        loadingView.addSubview(blur)
        
        // Create animated loader
        let loader = NVActivityIndicatorView(frame: CGRect(x: loadingView.bounds.width/2 - 20,
                                                           y: 0,
                                                           width: 40, height: loadingView.bounds.height),
                                             type: .ballPulse,
                                             color: .lightGray)
        loader.startAnimating()
        loadingView.addSubview(loader)
        
        // Load image
        let resourceName = self.faceModel.properties.config?["placeholder_image"]?.stringValue ?? "ActivatedImage"
        guard let resourceURL = self.vatom.props.resources.first(where: { $0.name == resourceName })?.url, let encodedURL = try? BLOCKv.encodeURL(resourceURL) else {
            completion?(Face3DError("Couldn't find the placeholder image " + resourceName))
            return
        }
        
        // Load image
        Nuke.loadImage(with: encodedURL, into: imageView) { result in
            // Placeholder image loaded, display the view
            do {
                try result.get()
                completion?(nil)
            } catch {
                completion?(error)
            }
            
        }
        
        // Start loading the web content
        self.loadScene()
        
    }
    
    /// Called when the user clicks on the error button
    @objc private func onErrorButtonClick() {
        
        // Get error text
        let txt = self.error?.localizedDescription ?? "An unknown error occurred."
        
        // Show in an alert
        let alert = UIAlertController.init(title: "3D Error", message: txt, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Close", style: .default, handler: nil))
        
        // Find topmost view controller
        var bestVC = UIApplication.shared.keyWindow?.rootViewController
        while (bestVC?.presentedViewController != nil) {
            bestVC = bestVC?.presentedViewController
        }
        
        // Show error
        bestVC?.present(alert, animated: true, completion: nil)
        
    }
    
    /// Called when the vatom state changes. NOTE: Can also be called when a new vatom is displayed, to reuse resources.
    public func vatomChanged(_ vatom: VatomModel) {
        
        // TODO: Check if vatom ID changed
        
        // encode response
        guard
            let data = try? JSONEncoder.blockv.encode(vatom),
            let jsonString = String.init(data: data, encoding: .utf8) else {
                // handle error
                print("[3D Face] Error: Unable to encode vatom.")
                return
        }
        
        DispatchQueue.main.async {
            let controlString = "vatomStateChanged(\(jsonString))"
            self.webView?.evaluateJavaScript(controlString, completionHandler: nil)
        }
        
    }
    
    /// Called when the face is unloaded
    public func unload() {
        
        // Remove our reference to the web view
        self.webView?.removeFromSuperview()
        self.webView = nil
        
    }
    
    /// Get the resource URL for the specified resource name
    ///
    /// - Parameter name: Resource name
    /// - Returns: Unsigned URL of the resource, or nil
    func getResourceURL(name : String?) -> URL? {
        
        // Stop if no name
        guard let name = name else {
            return nil
        }
        
        // Find the resource
        return self.vatom.props.resources.first(where: { $0.name == name })?.url
        
    }
    
    /// Show the error view if unable to load
    ///
    /// - Parameter error: The error to show
    func show(error: Error) {
        
        // Show error view
        self.errorView.isHidden = false
        self.error = error
        
    }
    
    static let baseURL = Bundle.withResources.resourceURL!
    
    /** Load and display the 3D content */
    func loadScene() {
        
        print("[3DFace] \(#function)")
        
        // Get scene resource
        guard let resourceURL = getResourceURL(name: self.faceModel.properties.config?["scene"]?.stringValue) ?? getResourceURL(name: "Scene.glb") ?? getResourceURL(name: "Scene") else {
            return show(error: Face3DError("No scene resource found."))
        }
        
        // Show loader
        UIView.animate(withDuration: 0.35, animations: {
            self.loadingView.alpha = 1
        })
        
        // Get signed URL
        guard let signedURL = try? BLOCKv.encodeURL(resourceURL) else {
            return show(error: Face3DError("Unable to sign the resource URL."))
        }
        
        // Get urls for the environment map
        let baseURL = Face3D.baseURL
        
        // Get animation rules, if any. TODO: Read from face config section once supported
        let animRules : [JSON] = self.faceModel.properties.config?["animation_rules"]?.arrayValue ?? self.vatom.private?["animation_rules"]?.arrayValue ?? []
        
        // Create data to inject. HACK: vatomPayload should be the raw vatom payload!
        let injectedInfo = JSON.object([
            "modelFilename": JSON.string(resourceURL.lastPathComponent),
            "modelURL": JSON.string(signedURL.absoluteString),
            "animationRules": JSON.array(animRules),
            "vatomPayload": self.vatom.toJSON,
            "facePayload": self.faceModel.toJSON
            ])
        
        // Create web view config
        let config = WKWebViewConfiguration()
        // see: https://stackoverflow.com/a/41266699/3589408
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.allowsInlineMediaPlayback = true
        
        // Inject function to let the web app get the URL of the model
        config.userContentController.addUserScript(WKUserScript(source: "window.rendererInfo = " + injectedInfo.jsonString, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        
        // Add bridge to tell us when the web app is loaded
        config.userContentController.add(self, name: "nativeBridge")
        
        // Create web view
        self.webView = WKWebView(frame: self.bounds, configuration: config)
        self.webView?.autoresizingMask = [ .flexibleWidth, .flexibleHeight ]
        self.webView?.alpha = 0
        self.webView?.isOpaque = false
        self.webView?.navigationDelegate = self
        self.addSubview(webView!)
        
        // Prevent web view from adding insets to the view
        if #available(iOS 11.0, *) {
            self.webView?.scrollView.contentInsetAdjustmentBehavior = .never
        }
        
        // Load renderer web app
        let contentURL = faceCacheDirectoryURL.appendingPathComponent("index.html")
        self.webView?.loadFileURL(contentURL, allowingReadAccessTo: faceCacheDirectoryURL)
        
        print("[3D Face] Base URL: ", baseURL) //FIXME: Change
        
    }
    
    deinit {
        print(#function)
    }
    
    /** Called when the web app has a message to pass to us */
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        
        // Decode JSON
        guard let json = message.body as? [String:Any] else {
            print("[3D Face] Unknown message type received from the web view")
            return
        }
        
        // Get action name
        guard let action = (json["action"] as? String)?.lowercased() else {
            print("[3D Face] No action field in message received from the web view")
            return
        }
        
        // Check action
        if action == "log" {
            
            // Log from the web app
            print("[3D Face] " + (json["text"] as? String ?? ""))
            
        } else if action == "load" {
            
            // Log from the web app
            print("[3D Face] Load complete triggered")
            
            // Transition from icon view to scene view
            UIView.animate(withDuration: 0.35) {
                
                // Fade scene view in
                self.webView?.alpha = 1
                self.imageView.alpha = 0
                self.loadingView.alpha = 0
                
            }
            
        } else if action == "loadfail" {
            
            // Log from the web app
            let error = Face3DError(json["text"] as? String ?? "Unknown web app error occurred.")
            print("[3D Face] Load fail triggered: " + error.localizedDescription)
            
            // Show error
            self.errorView.isHidden = false
            self.error = error
            
        } else if action == "sign-url" {
            
            // Request to sign the specified URL, get params
            guard let id = json["id"] as? String, let urlStr = json["url"] as? String, let url = URL(string: urlStr) else {
                print("[3D Face] Incorrect data for sign-url request")
                return
            }
            
            // Sign the URL
            guard let signedURL = try? BLOCKv.encodeURL(url) else {
                
                // Back to the main thread
                DispatchQueue.main.async {
                    
                    // Failed to sign the URL, inform the web app
                    self.webView?.evaluateJavaScript("signURLFailed(\(JSON.string(id).jsonString), \"Unable to sign the resource URL.\")", completionHandler: nil)
                    print("[3D Face] Unable to sign the resurce URL.")
                    
                    
                }
                
                return
                
            }
            
            /// Download data
            DataPipeline.shared.downloadData(url: signedURL, progress: { progress in
                // no-op
            }) { result in

                switch result {
                case .success(let url):
                    DispatchQueue.main.async {
                        // send final URL to the web app
                        print("[3D Face] Received file url: \(url)")
                        self.webView?.evaluateJavaScript("signURLComplete(\(JSON.string(id).jsonString), \"\(url)\")", completionHandler: nil)
                    }

                case .failure(let error):
                    DispatchQueue.main.async {
                        // failed to download, inform the web app
                        self.webView?.evaluateJavaScript("signURLFailed(\(JSON.string(id).jsonString), \"Unable to download the resource. \" + \(JSON.string(error.localizedDescription).jsonString))", completionHandler: nil)
                        print("[3D Face] Unable to download the resurce. " + error.localizedDescription)

                    }
                }

            }
            
            return
            
        } else {
            
            // Unknown action
            print("[3D Face] Unknown action '\(action)' in message received from the web view")
            
        }
        
    }
    
    /// Called if the WKWebView process crashes
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        
        // Create error
        print("[3D Face] Renderer process has been terminated.")
        let error = Face3DError("Renderer process has been terminated.")
        
        // Show error
        self.errorView.isHidden = false
        self.error = error
    }
    
    /** Called by VatomView when the vatom's state changes */
    func vatomStateChanged() {
        
        let jsonString = self.vatom.toJSON.jsonString
        
        // Back to the main thread
        DispatchQueue.main.async {
            
            // Notify the web view
            self.webView?.evaluateJavaScript("vatomStateChanged(\(jsonString))", completionHandler: nil)
            
        }
        
    }
    
}

public struct Face3DError : LocalizedError {
    
    /// A message describing the error
    public var errorDescription : String?
    
    /// Constructor
    internal init(_ text: String) {
        self.errorDescription = text
    }
    
}
