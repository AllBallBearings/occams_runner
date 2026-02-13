import SwiftUI
import ARKit
import RealityKit
import CoreLocation
import Combine

/// The AR running experience. Shows floating gold coins along the quest route.
/// Coins are collected when the runner gets within ~5 feet of them.
struct ARRunnerView: View {
    @EnvironmentObject var dataStore: DataStore
    @EnvironmentObject var locationService: LocationService
    @Environment(\.dismiss) private var dismiss

    let quest: Quest

    @State private var collectedCount = 0
    @State private var totalPoints = 0
    @State private var showingCompletionAlert = false
    @State private var nearestItemDistance: Double?

    var body: some View {
        ZStack {
            // AR View
            ARRunnerContainerView(
                quest: quest,
                dataStore: dataStore,
                locationService: locationService,
                onItemCollected: { itemId in
                    handleCollection(itemId: itemId)
                }
            )
            .ignoresSafeArea()

            // HUD overlay
            VStack {
                hudOverlay
                Spacer()
                bottomBar
            }
        }
        .onAppear {
            locationService.startUpdating()
            let currentQuest = dataStore.quests.first(where: { $0.id == quest.id }) ?? quest
            collectedCount = currentQuest.collectedItems
            totalPoints = currentQuest.collectedPoints
        }
        .alert("Quest Complete!", isPresented: $showingCompletionAlert) {
            Button("Finish") { dismiss() }
        } message: {
            Text("You collected all \(quest.totalItems) coins for \(quest.totalPoints) points!")
        }
    }

    // MARK: - HUD

    private var hudOverlay: some View {
        HStack(spacing: 20) {
            // Coins collected
            HStack(spacing: 6) {
                Image(systemName: "circle.circle.fill")
                    .foregroundColor(.yellow)
                Text("\(collectedCount)/\(quest.totalItems)")
                    .fontWeight(.bold)
            }

            // Points
            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                Text("\(totalPoints) pts")
                    .fontWeight(.bold)
            }

            Spacer()

            // Close button
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var bottomBar: some View {
        HStack {
            if let distance = nearestItemDistance {
                HStack(spacing: 6) {
                    Image(systemName: "location.circle")
                        .foregroundColor(.orange)
                    Text(String(format: "Next coin: %.0f ft", distance * 3.281))
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .cornerRadius(20)
            }
        }
        .padding(.bottom, 40)
    }

    // MARK: - Collection

    private func handleCollection(itemId: UUID) {
        dataStore.updateQuestItem(questId: quest.id, itemId: itemId, collected: true)
        collectedCount += 1
        totalPoints += QuestItemType.coin.pointValue

        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        let currentQuest = dataStore.quests.first(where: { $0.id == quest.id }) ?? quest
        if currentQuest.isComplete {
            showingCompletionAlert = true
        }
    }
}

// MARK: - AR Container (UIViewRepresentable)

struct ARRunnerContainerView: UIViewRepresentable {
    let quest: Quest
    let dataStore: DataStore
    let locationService: LocationService
    let onItemCollected: (UUID) -> Void

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.delegate = context.coordinator
        arView.autoenablesDefaultLighting = true
        arView.automaticallyUpdatesLighting = true

        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        config.planeDetection = []
        arView.session.run(config)

        context.coordinator.arView = arView

        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.updateItems(quest: quest, dataStore: dataStore)
    }

    func makeCoordinator() -> ARCoordinator {
        ARCoordinator(
            quest: quest,
            dataStore: dataStore,
            locationService: locationService,
            onItemCollected: onItemCollected
        )
    }
}

// MARK: - AR Coordinator

class ARCoordinator: NSObject, ARSCNViewDelegate {
    var arView: ARSCNView?
    var quest: Quest
    let dataStore: DataStore
    let locationService: LocationService
    let onItemCollected: (UUID) -> Void

    private var coinNodes: [UUID: SCNNode] = [:]
    private var collectionTimer: Timer?
    private var placedItems = false

    init(quest: Quest, dataStore: DataStore, locationService: LocationService, onItemCollected: @escaping (UUID) -> Void) {
        self.quest = quest
        self.dataStore = dataStore
        self.locationService = locationService
        self.onItemCollected = onItemCollected
        super.init()

        // Start checking for collections
        collectionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkCollections()
        }
    }

    deinit {
        collectionTimer?.invalidate()
    }

    func updateItems(quest: Quest, dataStore: DataStore) {
        self.quest = quest

        guard let arView = arView, let currentLocation = locationService.currentLocation else { return }

        let currentQuest = dataStore.quests.first(where: { $0.id == quest.id }) ?? quest

        // Place or update coin nodes
        for item in currentQuest.items {
            if item.collected {
                // Remove collected coins
                if let node = coinNodes[item.id] {
                    node.removeFromParentNode()
                    coinNodes.removeValue(forKey: item.id)
                }
                continue
            }

            if coinNodes[item.id] == nil {
                // Calculate position relative to user
                let itemLocation = item.location
                let distance = currentLocation.distance(from: itemLocation)

                // Only render items within 100 meters for performance
                guard distance < 100 else { continue }

                let bearing = currentLocation.bearing(to: itemLocation)
                let altDiff = item.altitude - currentLocation.altitude

                // Convert GPS offset to AR scene coordinates
                // ARKit: x = east, y = up, z = south (with gravityAndHeading alignment)
                let dx = Float(distance * sin(bearing))
                let dy = Float(altDiff) + 1.5 // Float coins 1.5m above ground
                let dz = Float(-distance * cos(bearing))

                let coinNode = createCoinNode()
                coinNode.position = SCNVector3(dx, dy, dz)
                arView.scene.rootNode.addChildNode(coinNode)
                coinNodes[item.id] = coinNode
            }
        }
    }

    private func createCoinNode() -> SCNNode {
        // Create a golden disc (coin)
        let coin = SCNCylinder(radius: 0.15, height: 0.02)

        let goldMaterial = SCNMaterial()
        goldMaterial.diffuse.contents = UIColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0)
        goldMaterial.specular.contents = UIColor.white
        goldMaterial.metalness.contents = 0.8
        goldMaterial.roughness.contents = 0.2
        goldMaterial.emission.contents = UIColor(red: 0.6, green: 0.45, blue: 0.0, alpha: 1.0)

        coin.materials = [goldMaterial]

        let coinNode = SCNNode(geometry: coin)

        // Add glow effect with a slightly larger transparent sphere
        let glow = SCNSphere(radius: 0.2)
        let glowMaterial = SCNMaterial()
        glowMaterial.diffuse.contents = UIColor(red: 1.0, green: 0.9, blue: 0.3, alpha: 0.15)
        glowMaterial.emission.contents = UIColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 0.3)
        glowMaterial.isDoubleSided = true
        glow.materials = [glowMaterial]
        let glowNode = SCNNode(geometry: glow)
        coinNode.addChildNode(glowNode)

        // Spinning animation
        let spin = CABasicAnimation(keyPath: "rotation")
        spin.toValue = NSValue(scnVector4: SCNVector4(0, 1, 0, Float.pi * 2))
        spin.duration = 2.0
        spin.repeatCount = .infinity
        coinNode.addAnimation(spin, forKey: "spin")

        // Bobbing animation
        let bob = CABasicAnimation(keyPath: "position.y")
        bob.byValue = 0.1
        bob.duration = 1.0
        bob.autoreverses = true
        bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        coinNode.addAnimation(bob, forKey: "bob")

        return coinNode
    }

    private func checkCollections() {
        guard let _ = locationService.currentLocation else { return }

        let currentQuest = dataStore.quests.first(where: { $0.id == quest.id }) ?? quest

        for item in currentQuest.items {
            guard !item.collected else { continue }

            if locationService.isWithinCollectionRange(of: item) {
                // Collect this item!
                if let node = coinNodes[item.id] {
                    // Collection animation
                    let scaleUp = SCNAction.scale(to: 2.0, duration: 0.2)
                    let fadeOut = SCNAction.fadeOut(duration: 0.3)
                    let group = SCNAction.group([scaleUp, fadeOut])
                    let remove = SCNAction.removeFromParentNode()
                    node.runAction(SCNAction.sequence([group, remove]))
                    coinNodes.removeValue(forKey: item.id)
                }

                DispatchQueue.main.async {
                    self.onItemCollected(item.id)
                }
            }
        }
    }
}

// MARK: - CLLocation Bearing Extension

extension CLLocation {
    /// Calculate bearing from this location to another location in radians.
    func bearing(to destination: CLLocation) -> Double {
        let lat1 = coordinate.latitude.degreesToRadians
        let lon1 = coordinate.longitude.degreesToRadians
        let lat2 = destination.coordinate.latitude.degreesToRadians
        let lon2 = destination.coordinate.longitude.degreesToRadians

        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)

        return atan2(y, x)
    }
}

extension Double {
    var degreesToRadians: Double { self * .pi / 180 }
    var radiansToDegrees: Double { self * 180 / .pi }
}
