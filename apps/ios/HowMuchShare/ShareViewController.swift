import SwiftUI
import UIKit

@objc(ShareViewController)
final class ShareViewController: UIViewController {
  private let model = ShareSheetModel()
  private var hasLoaded = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    model.onFinish = { [weak self] in
      self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
    let host = UIHostingController(rootView: ShareSheetView(model: model))
    host.view.backgroundColor = .clear
    host.view.translatesAutoresizingMaskIntoConstraints = false
    addChild(host)
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    host.didMove(toParent: self)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !hasLoaded else { return }
    hasLoaded = true
    let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
    let scale = traitCollection.displayScale
    Task { await model.load(from: items, displayScale: scale) }
  }
}
