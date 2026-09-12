import SceneKit

/// The single coin used by quests, route previews, and the AR asset tester.
enum StarCoinAsset {
    static let fileName = "StarCoin.usdz"
    static let diameter: Float = 0.26

    // Load once and clone the hierarchy for each collectible. Keep the USDZ's
    // authored axis conversion and PBR materials on the cloned content.
    private static let template: SCNNode? = {
        for directory in [nil, "3DModels", "Models/3DModels"] as [String?] {
            guard let url = Bundle.main.url(forResource: "StarCoin", withExtension: "usdz", subdirectory: directory),
                  let scene = try? SCNScene(url: url, options: nil) else { continue }
            let content = SCNNode()
            for child in scene.rootNode.childNodes {
                content.addChildNode(child.clone())
            }
            return content
        }
        assertionFailure("Missing or unreadable bundled asset: \(fileName)")
        return nil
    }()

    static func makeNode(bobs: Bool = true) -> SCNNode {
        let root = SCNNode()
        root.name = "StarCoin"
        guard let visual = template?.clone() else { return root }

        let spinPivot = SCNNode()
        spinPivot.name = "StarCoinSpin"
        spinPivot.addChildNode(visual)
        root.addChildNode(spinPivot)

        let spin = CABasicAnimation(keyPath: "rotation")
        spin.toValue = NSValue(scnVector4: SCNVector4(0, 1, 0, Float.pi * 2))
        spin.duration = 2.0
        spin.repeatCount = .infinity
        spinPivot.addAnimation(spin, forKey: "spin")

        if bobs {
            let bob = CABasicAnimation(keyPath: "position.y")
            bob.byValue = 0.1
            bob.duration = 1.0
            bob.autoreverses = true
            bob.repeatCount = .infinity
            bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            root.addAnimation(bob, forKey: "bob")
        }
        return root
    }
}
