import SwiftUI
import ARKit
import SceneKit
import Vision

struct ARAssetPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAsset = ARPreviewAsset.library[0]
    @State private var itemMenuExpanded = false

    var body: some View {
        ZStack(alignment: .top) {
            ARAssetPreviewContainerView(selectedAsset: selectedAsset)
                .ignoresSafeArea()

            HStack(alignment: .top) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .black))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(.black.opacity(0.42))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                itemMenu
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
        }
        .statusBarHidden()
    }

    private var itemMenu: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    itemMenuExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Text("Item")
                        .font(.system(size: 13, weight: .black))
                    Image(systemName: itemMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .black))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 13)
                .frame(height: 36)
                .background(.black.opacity(0.46))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            if itemMenuExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(ARPreviewAsset.library) { asset in
                            Button {
                                selectedAsset = asset
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    itemMenuExpanded = false
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Text(asset.displayName)
                                        .font(.system(size: 12, weight: .bold))
                                        .lineLimit(1)
                                    Spacer(minLength: 10)
                                    if asset == selectedAsset {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .black))
                                    }
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 11)
                                .frame(width: 176, height: 32)
                                .background(asset == selectedAsset ? Color.orange.opacity(0.82) : Color.white.opacity(0.10))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(7)
                }
                .frame(width: 190, height: 280)
                .background(.black.opacity(0.50))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

private struct ARAssetPreviewContainerView: UIViewRepresentable {
    let selectedAsset: ARPreviewAsset

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedAsset: selectedAsset)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.delegate = context.coordinator
        view.session.delegate = context.coordinator
        view.automaticallyUpdatesLighting = true
        view.autoenablesDefaultLighting = true
        view.scene = SCNScene()
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.setAsset(selectedAsset, in: uiView)
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    final class Coordinator: NSObject, ARSCNViewDelegate, ARSessionDelegate {
        private weak var sceneView: ARSCNView?
        private var selectedAsset: ARPreviewAsset
        private var previewNode: SCNNode?
        private let handPoseRequest: VNDetectHumanHandPoseRequest = {
            let request = VNDetectHumanHandPoseRequest()
            request.maximumHandCount = 1
            return request
        }()
        private var lastHandPoseTime: TimeInterval = 0
        private let handPoseInterval: TimeInterval = 0.10
        private var lastBoxHitTime: TimeInterval = 0

        init(selectedAsset: ARPreviewAsset) {
            self.selectedAsset = selectedAsset
            super.init()
        }

        func attach(to view: ARSCNView) {
            sceneView = view

            let configuration = ARWorldTrackingConfiguration()
            configuration.worldAlignment = .gravity
            configuration.planeDetection = [.horizontal]
            view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak view] in
                guard let self, let view else { return }
                self.placeSelectedAsset(in: view)
            }
        }

        func setAsset(_ asset: ARPreviewAsset, in view: ARSCNView) {
            guard asset != selectedAsset || previewNode == nil else { return }
            selectedAsset = asset
            placeSelectedAsset(in: view)
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            guard selectedAsset.behavior == .box else { return }
            guard frame.timestamp - lastHandPoseTime >= handPoseInterval else { return }
            lastHandPoseTime = frame.timestamp
            processHandPose(frame: frame)
        }

        private func placeSelectedAsset(in view: ARSCNView) {
            previewNode?.removeFromParentNode()

            let node = makePreviewNode(for: selectedAsset)
            node.simdWorldPosition = positionOneMeterInFront(of: view)
            node.eulerAngles.y = cameraYaw(in: view)
            view.scene.rootNode.addChildNode(node)
            previewNode = node
        }

        private func makePreviewNode(for asset: ARPreviewAsset) -> SCNNode {
            if asset.behavior == .coin {
                return makeCoinPreviewNode(for: asset)
            }

            let node = loadModelNode(for: asset) ?? fallbackNode(for: asset)
            return node
        }

        private func makeCoinPreviewNode(for asset: ARPreviewAsset) -> SCNNode {
            let root = SCNNode()
            let spinPivot = SCNNode()
            let visual = makeTexturedCoinNode(for: asset)
                ?? loadModelNode(for: asset)
                ?? fallbackNode(for: asset)

            visual.removeAnimationsRecursively()
            visual.eulerAngles.x += asset.coinTiltRadians

            spinPivot.addChildNode(visual)
            root.addChildNode(spinPivot)
            addCoinAnimations(toRoot: root, spinPivot: spinPivot)
            return root
        }

        private func makeTexturedCoinNode(for asset: ARPreviewAsset) -> SCNNode? {
            guard let textureFileName = asset.textureFileName,
                  let texture = loadImage(fileName: textureFileName) else { return nil }

            let radius = CGFloat(asset.targetSize) * 0.48
            let height = CGFloat(asset.targetSize) * 0.10
            let coin = SCNCylinder(radius: radius, height: height)
            coin.radialSegmentCount = 96
            coin.materials = [
                material(color: UIColor(red: 0.95, green: 0.55, blue: 0.12, alpha: 1), emission: 0.08),
                texturedMaterial(image: texture),
                texturedMaterial(image: texture)
            ]
            return SCNNode(geometry: coin)
        }

        private func loadImage(fileName: String) -> UIImage? {
            let nsName = fileName as NSString
            let base = nsName.deletingPathExtension
            let ext = nsName.pathExtension
            let subdirectories = ["3DModels", "Models/3DModels", nil]

            for subdirectory in subdirectories {
                if let url = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: subdirectory),
                   let image = UIImage(contentsOfFile: url.path) {
                    return image
                }
            }
            return UIImage(named: fileName)
        }

        private func loadModelNode(for asset: ARPreviewAsset) -> SCNNode? {
            guard let scene = loadScene(fileName: asset.fileName) else { return nil }
            let content = SCNNode()
            for child in scene.rootNode.childNodes {
                content.addChildNode(child.clone())
            }
            return centeredNode(content, targetSize: asset.targetSize)
        }

        private func loadScene(fileName: String) -> SCNScene? {
            let candidates = [
                "3DModels/\(fileName)",
                "Models/3DModels/\(fileName)",
                fileName
            ]
            for candidate in candidates {
                if let scene = SCNScene(named: candidate) {
                    return scene
                }
            }

            let nsName = fileName as NSString
            let base = nsName.deletingPathExtension
            let ext = nsName.pathExtension
            let subdirectories = ["3DModels", "Models/3DModels", nil]
            for subdirectory in subdirectories {
                if let url = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: subdirectory),
                   let scene = try? SCNScene(url: url, options: nil) {
                    return scene
                }
            }
            return nil
        }

        private func centeredNode(_ content: SCNNode, targetSize: Float) -> SCNNode {
            let (minBounds, maxBounds) = content.boundingBox
            let width = maxBounds.x - minBounds.x
            let height = maxBounds.y - minBounds.y
            let depth = maxBounds.z - minBounds.z
            let largestDimension = max(width, max(height, depth))
            guard largestDimension > 0.0001 else { return content }

            let scale = targetSize / largestDimension
            let center = SCNVector3(
                (minBounds.x + maxBounds.x) * 0.5,
                (minBounds.y + maxBounds.y) * 0.5,
                (minBounds.z + maxBounds.z) * 0.5
            )

            let wrapper = SCNNode()
            content.scale = SCNVector3(scale, scale, scale)
            content.position = SCNVector3(-center.x * scale, -center.y * scale, -center.z * scale)
            wrapper.addChildNode(content)
            return wrapper
        }

        private func fallbackNode(for asset: ARPreviewAsset) -> SCNNode {
            switch asset.behavior {
            case .coin:
                let coin = SCNCylinder(radius: 0.12, height: 0.024)
                coin.radialSegmentCount = 48
                coin.materials = [material(color: UIColor(red: 1.0, green: 0.54, blue: 0.08, alpha: 1), emission: 0.18)]
                let node = SCNNode(geometry: coin)
                node.eulerAngles.x = .pi / 2
                return node
            case .box:
                let box = SCNBox(width: 0.30, height: 0.30, length: 0.30, chamferRadius: 0.02)
                box.materials = [material(color: UIColor(red: 0.55, green: 0.35, blue: 0.15, alpha: 1), emission: 0.04)]
                return SCNNode(geometry: box)
            case .staticModel:
                let sphere = SCNSphere(radius: 0.15)
                sphere.materials = [material(color: UIColor(red: 0.15, green: 0.55, blue: 0.95, alpha: 1), emission: 0.07)]
                return SCNNode(geometry: sphere)
            }
        }

        private func material(color: UIColor, emission: CGFloat) -> SCNMaterial {
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.emission.contents = color.withAlphaComponent(emission)
            material.specular.contents = UIColor(white: 1.0, alpha: 0.35)
            material.roughness.contents = NSNumber(value: 0.45)
            material.isDoubleSided = true
            return material
        }

        private func texturedMaterial(image: UIImage) -> SCNMaterial {
            let material = SCNMaterial()
            material.diffuse.contents = image
            material.diffuse.mipFilter = .linear
            material.diffuse.minificationFilter = .linear
            material.diffuse.magnificationFilter = .linear
            material.specular.contents = UIColor(white: 1.0, alpha: 0.28)
            material.roughness.contents = NSNumber(value: 0.42)
            material.isDoubleSided = true
            return material
        }

        private func addCoinAnimations(toRoot root: SCNNode, spinPivot: SCNNode) {
            root.removeAllActions()
            spinPivot.removeAllActions()

            let spin = SCNAction.repeatForever(.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 2.0))
            spin.timingMode = .linear
            spinPivot.runAction(spin, forKey: "spin")

            let bobUp = SCNAction.moveBy(x: 0, y: 0.10, z: 0, duration: 1.0)
            bobUp.timingMode = .easeInEaseOut
            let bobDown = SCNAction.moveBy(x: 0, y: -0.10, z: 0, duration: 1.0)
            bobDown.timingMode = .easeInEaseOut
            root.runAction(.repeatForever(.sequence([bobUp, bobDown])), forKey: "bob")
        }

        private func positionOneMeterInFront(of view: ARSCNView) -> SIMD3<Float> {
            guard let frame = view.session.currentFrame else {
                return SIMD3<Float>(0, 0, -1)
            }
            let transform = frame.camera.transform
            let cameraPosition = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let forward = SIMD3<Float>(-transform.columns.2.x, -transform.columns.2.y, -transform.columns.2.z)
            return cameraPosition + simd_normalize(forward) * 1.0
        }

        private func cameraYaw(in view: ARSCNView) -> Float {
            guard let frame = view.session.currentFrame else { return 0 }
            let transform = frame.camera.transform
            let forward = SIMD3<Float>(-transform.columns.2.x, 0, -transform.columns.2.z)
            guard simd_length(forward) > 0.0001 else { return 0 }
            let normalized = simd_normalize(forward)
            return atan2(normalized.x, normalized.z)
        }

        private func processHandPose(frame: ARFrame) {
            let handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage, options: [:])
            do {
                try handler.perform([handPoseRequest])
            } catch {
                return
            }

            guard let observation = handPoseRequest.results?.first,
                  detectFistPose(observation) else { return }

            checkBoxHit(fistPosition: fistWorldPosition(frame: frame), timestamp: frame.timestamp)
        }

        private func detectFistPose(_ observation: VNHumanHandPoseObservation) -> Bool {
            guard let wrist = try? observation.recognizedPoint(.wrist),
                  let indexTip = try? observation.recognizedPoint(.indexTip),
                  let indexMCP = try? observation.recognizedPoint(.indexMCP),
                  let middleTip = try? observation.recognizedPoint(.middleTip),
                  let middleMCP = try? observation.recognizedPoint(.middleMCP) else { return false }

            let minConfidence: Float = 0.4
            guard wrist.confidence > minConfidence,
                  indexTip.confidence > minConfidence,
                  indexMCP.confidence > minConfidence,
                  middleTip.confidence > minConfidence,
                  middleMCP.confidence > minConfidence else { return false }

            func distance(_ point: VNRecognizedPoint, _ x: Double, _ y: Double) -> Double {
                let dx = point.location.x - x
                let dy = point.location.y - y
                return sqrt(dx * dx + dy * dy)
            }

            let palmX = (indexMCP.location.x + middleMCP.location.x) / 2
            let palmY = (indexMCP.location.y + middleMCP.location.y) / 2
            let scale = distance(indexMCP, wrist.location.x, wrist.location.y)
            guard scale > 0.01 else { return false }

            return distance(indexTip, palmX, palmY) / scale < 0.7
                && distance(middleTip, palmX, palmY) / scale < 0.7
        }

        private func fistWorldPosition(frame: ARFrame) -> SIMD3<Float> {
            let transform = frame.camera.transform
            let cameraPosition = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let forward = SIMD3<Float>(-transform.columns.2.x, -transform.columns.2.y, -transform.columns.2.z)
            return cameraPosition + simd_normalize(forward) * 0.6
        }

        private func checkBoxHit(fistPosition: SIMD3<Float>, timestamp: TimeInterval) {
            guard timestamp - lastBoxHitTime > 0.55,
                  let node = previewNode else { return }

            if simd_distance(fistPosition, node.simdWorldPosition) < 0.5 {
                lastBoxHitTime = timestamp
                showBoxHit(on: node)
            }
        }

        private func showBoxHit(on node: SCNNode) {
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.impactOccurred()

            node.runAction(.sequence([
                .scale(to: 0.88, duration: 0.05),
                .scale(to: 1.0, duration: 0.14)
            ]))

            guard let sceneView else { return }
            let burstNode = SCNNode()
            burstNode.simdWorldPosition = node.simdWorldPosition
            sceneView.scene.rootNode.addChildNode(burstNode)

            let particles = SCNParticleSystem()
            particles.particleColor = UIColor(red: 0.95, green: 0.48, blue: 0.08, alpha: 1.0)
            particles.particleColorVariation = SCNVector4(0.18, 0.12, 0.04, 0)
            particles.particleLifeSpan = 0.45
            particles.particleLifeSpanVariation = 0.18
            particles.birthRate = 280
            particles.emissionDuration = 0.05
            particles.spreadingAngle = 150
            particles.particleVelocity = 1.8
            particles.particleVelocityVariation = 0.8
            particles.particleSize = 0.025
            particles.particleSizeVariation = 0.012
            particles.isAffectedByGravity = true
            particles.loops = false
            burstNode.addParticleSystem(particles)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak burstNode] in
                burstNode?.removeFromParentNode()
            }
        }
    }
}

private struct ARPreviewAsset: Identifiable, Equatable {
    enum Behavior {
        case coin
        case box
        case staticModel
    }

    let displayName: String
    let fileName: String
    let behavior: Behavior
    let targetSize: Float
    let textureFileName: String?
    let coinTiltRadians: Float

    var id: String { fileName }

    init(
        displayName: String,
        fileName: String,
        behavior: Behavior,
        targetSize: Float,
        textureFileName: String? = nil,
        coinTiltRadians: Float = .pi / 2
    ) {
        self.displayName = displayName
        self.fileName = fileName
        self.behavior = behavior
        self.targetSize = targetSize
        self.textureFileName = textureFileName
        self.coinTiltRadians = coinTiltRadians
    }

    static let library: [ARPreviewAsset] = [
        ARPreviewAsset(displayName: "King Coin", fileName: "VoxelKingCoin.usdz", behavior: .coin, targetSize: 0.26, coinTiltRadians: 0),
        ARPreviewAsset(displayName: "Fire Coin", fileName: "fire_coin_subsurface.usdz", behavior: .coin, targetSize: 0.26),
        ARPreviewAsset(displayName: "Coin", fileName: "Coin.usdz", behavior: .coin, targetSize: 0.26),
        ARPreviewAsset(displayName: "Voxel Coin", fileName: "VoxelCoin.usdz", behavior: .coin, targetSize: 0.26),
        ARPreviewAsset(displayName: "Voxel Loot Box", fileName: "VoxelLootBox.usdz", behavior: .box, targetSize: 0.34),
        ARPreviewAsset(displayName: "Voxel Ruby Gem", fileName: "VoxelRubyGem.usdz", behavior: .staticModel, targetSize: 0.32),
        ARPreviewAsset(displayName: "Voxel Emerald Gem", fileName: "VoxelEmeraldGem.usdz", behavior: .staticModel, targetSize: 0.32),
        ARPreviewAsset(displayName: "Voxel Diamond Gem", fileName: "VoxelDiamondGem.usdz", behavior: .staticModel, targetSize: 0.32),
        ARPreviewAsset(displayName: "Voxel Jewel Cluster", fileName: "VoxelJewelCluster.usdz", behavior: .staticModel, targetSize: 0.36),
        ARPreviewAsset(displayName: "Voxel Potion Bottle", fileName: "VoxelPotionBottle.usdz", behavior: .staticModel, targetSize: 0.34),
        ARPreviewAsset(displayName: "Voxel Spinach Can", fileName: "VoxelSpinachCan.usdz", behavior: .staticModel, targetSize: 0.34),
        ARPreviewAsset(displayName: "Voxel Fireball", fileName: "VoxelFireball.usdz", behavior: .staticModel, targetSize: 0.34),
        ARPreviewAsset(displayName: "Voxel Ice Sword", fileName: "VoxelIceSword.usdz", behavior: .staticModel, targetSize: 0.42),
        ARPreviewAsset(displayName: "Voxel Bow Arrow", fileName: "VoxelBowArrow.usdz", behavior: .staticModel, targetSize: 0.42),
        ARPreviewAsset(displayName: "Voxel Boulder", fileName: "VoxelBoulder.usdz", behavior: .staticModel, targetSize: 0.36)
    ]
}

private extension SCNNode {
    func removeAnimationsRecursively() {
        removeAllAnimations()
        removeAllActions()
        for child in childNodes {
            child.removeAnimationsRecursively()
        }
    }
}
