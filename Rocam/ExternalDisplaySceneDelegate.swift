import UIKit

final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .black
        window.rootViewController = ExternalFeedViewController()
        window.isHidden = false
        self.window = window
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if let feed = window?.rootViewController as? ExternalFeedViewController {
            feed.stop()
        } else {
            AppServices.shared.setExternalDisplayActive(false)
        }
        window?.isHidden = true
        window = nil
    }
}

private final class ExternalFeedViewController: UIViewController {
    private let feed = UIView()
    private var displayLink: CADisplayLink?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        feed.backgroundColor = .black
        feed.layer.contentsGravity = .resizeAspect
        feed.layer.masksToBounds = true
        feed.frame = view.bounds
        feed.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(feed)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard displayLink == nil else { return }
        AppServices.shared.setExternalDisplayActive(true)
        let link = CADisplayLink(target: self, selector: #selector(showLatestFrame))
        let rate = Float(AppServices.shared.camera.frames.currentStreamFPS())
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stop()
    }

    func stop() {
        AppServices.shared.setExternalDisplayActive(false)
        displayLink?.invalidate()
        displayLink = nil
        feed.layer.contents = nil
    }

    @objc private func showLatestFrame() {
        let camera = AppServices.shared.camera
        let rate = Float(camera.frames.currentStreamFPS())
        if displayLink?.preferredFrameRateRange.preferred != rate {
            displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: rate, preferred: rate)
        }
        let image = camera.activeLens == .lidar
            ? camera.frames.latestDepthImage() ?? camera.frames.latestColorImage()
            : camera.frames.latestColorImage()
        feed.layer.contents = image
    }
}
