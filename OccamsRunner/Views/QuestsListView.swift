import SwiftUI
import MapKit

struct QuestsListView: View {
    @EnvironmentObject var dataStore: DataStore
    @State private var searchText = ""

    private var sortedQuests: [Quest] {
        let sorted = dataStore.quests.sorted { $0.dateCreated > $1.dateCreated }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    // Large display title
                    Text("My Quests")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)

                    // Search bar
                    searchBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)

                    if sortedQuests.isEmpty {
                        emptyState
                    } else {
                        ScrollView {
                            VStack(spacing: 14) {
                                ForEach(sortedQuests) { quest in
                                    NavigationLink(destination: QuestDetailView(quest: quest)) {
                                        questCard(quest)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            dataStore.deleteQuest(quest)
                                        } label: {
                                            Label("Delete Quest", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.white.opacity(0.45))
            TextField("Search quests...", text: $searchText)
                .foregroundColor(.white)
                .tint(.purple)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.1))
        .clipShape(Capsule())
    }

    // MARK: - Quest Card

    private func questCard(_ quest: Quest) -> some View {
        let route = dataStore.routes.first(where: { $0.id == quest.routeId })
        let (level, levelLabel) = questLevel(coinCount: quest.items.count)
        let progress = quest.totalItems > 0
            ? Double(quest.collectedItems) / Double(quest.totalItems)
            : 0

        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                // Map thumbnail
                Group {
                    if let route {
                        RouteSnapshotView(route: route)
                    } else {
                        ZStack {
                            Color(white: 0.12)
                            Image(systemName: "map.fill")
                                .foregroundColor(.white.opacity(0.25))
                                .font(.title)
                        }
                    }
                }
                .frame(width: 140, height: 115)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // Quest info
                VStack(alignment: .leading, spacing: 7) {
                    Text(quest.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let route {
                        Text(route.name)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                    }

                    // Quest level
                    Group {
                        Text("Quest Level: \(level): ").foregroundColor(.yellow)
                        + Text(levelLabel).foregroundColor(.yellow)
                    }
                    .font(.caption).fontWeight(.medium)

                    // Coins + points
                    Group {
                        Text("Coins: \(quest.totalItems) 🪙  ").foregroundColor(.white)
                        + Text("\(quest.totalPoints) pts").foregroundColor(.orange)
                    }
                    .font(.caption).fontWeight(.medium)

                    // Collected count if any progress
                    if quest.collectedItems > 0 {
                        Text("\(quest.collectedItems)/\(quest.totalItems) collected")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.top, 4)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // Progress bar
            if quest.totalItems > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.1))
                        Capsule()
                            .fill(progressColor(progress))
                            .frame(width: geo.size.width * CGFloat(progress))
                    }
                }
                .frame(height: 4)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }

            // Action button
            questActionButton(quest, progress: progress)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .background(Color(white: 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.purple.opacity(0.65), lineWidth: 1.5)
        )
        .shadow(color: Color.purple.opacity(0.28), radius: 10)
    }

    // MARK: - Action Button

    private func questActionButton(_ quest: Quest, progress: Double) -> some View {
        let (label, color): (String, Color) = {
            if quest.isComplete            { return ("Completed ✓",   .gray) }
            if quest.collectedItems > 0    { return ("Resume Quest",  .orange) }
            return ("Start Quest", .green)
        }()

        return Text(label)
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(quest.isComplete ? .white.opacity(0.5) : .black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(quest.isComplete ? Color.white.opacity(0.1) : color)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "star.circle")
                .font(.system(size: 60))
                .foregroundColor(.white.opacity(0.15))
            Text("No Quests Yet")
                .font(.title2).fontWeight(.semibold)
                .foregroundColor(.white.opacity(0.55))
            Text("Record a route, then create a quest from the Routes tab.")
                .font(.body)
                .foregroundColor(.white.opacity(0.35))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func questLevel(coinCount: Int) -> (level: Int, label: String) {
        switch coinCount {
        case 0:        return (0, "No Items")
        case 1...10:   return (1, "Coins Only")
        case 11...20:  return (2, "Collect Master")
        case 21...30:  return (3, "Monsters Enabled")
        case 31...40:  return (4, "Challenge Mode")
        default:       return (5, "Boss Battle!")
        }
    }

    private func progressColor(_ progress: Double) -> Color {
        if progress >= 1.0 { return .green }
        if progress > 0    { return .orange }
        return .cyan
    }
}
