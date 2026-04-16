import SwiftUI
import MapKit

struct QuestsListView: View {
    @EnvironmentObject var dataStore: DataStore
    @State private var searchText = ""

    // Rename state
    @State private var renamingQuest: Quest? = nil
    @State private var renameText = ""

    private var sortedQuests: [Quest] {
        let sorted = dataStore.quests.sorted { $0.dateCreated > $1.dateCreated }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                appBackground.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    // Large display title
                    Text("Quest Library")
                        .font(.system(size: 34, weight: .black))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 20)

                    // Search bar
                    searchBar
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)

                    if sortedQuests.isEmpty {
                        emptyState
                    } else {
                        ScrollView {
                            VStack(spacing: 18) {
                                ForEach(sortedQuests) { quest in
                                    NavigationLink(destination: QuestDetailView(quest: quest)) {
                                        questCard(quest)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button {
                                            renameText = quest.name
                                            renamingQuest = quest
                                        } label: {
                                            Label("Rename Quest", systemImage: "pencil")
                                        }
                                        Button(role: .destructive) {
                                            dataStore.deleteQuest(quest)
                                        } label: {
                                            Label("Delete Quest", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 30)
                        }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .alert("Rename Quest", isPresented: Binding(
                get: { renamingQuest != nil },
                set: { if !$0 { renamingQuest = nil } }
            )) {
                TextField("Quest name", text: $renameText)
                Button("Save") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                    if let quest = renamingQuest, !trimmed.isEmpty {
                        dataStore.renameQuest(quest, to: trimmed)
                    }
                    renamingQuest = nil
                }
                Button("Cancel", role: .cancel) { renamingQuest = nil }
            }
        }
    }

    private var appBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.07, blue: 0.18),
                Color(red: 0.86, green: 0.88, blue: 0.94)
            ],
            startPoint: .top, endPoint: .bottom)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.20).opacity(0.50))
                .font(.system(size: 16, weight: .bold))
            TextField("Search quests...", text: $searchText)
                .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.20))
                .tint(Color(red: 0.45, green: 0.35, blue: 0.80))
                .font(.body)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color(red: 0.76, green: 0.78, blue: 0.88))
        .clipShape(Capsule())
        .shadow(color: Color(red: 0.01, green: 0.01, blue: 0.04), radius: 8, x: 4, y: 4)
        .shadow(color: Color(red: 0.14, green: 0.16, blue: 0.28).opacity(0.40), radius: 6, x: -3, y: -3)
    }

    // MARK: - Quest Card

    private func questCard(_ quest: Quest) -> some View {
        let route = dataStore.routes.first(where: { $0.id == quest.routeId })
        let progress = quest.totalItems > 0
            ? Double(quest.collectedItems) / Double(quest.totalItems)
            : 0
        let purple = Color(red: 0.45, green: 0.35, blue: 0.80)
        let darkText = Color(red: 0.12, green: 0.13, blue: 0.20)
        let darkerSurface = Color(red: 0.68, green: 0.70, blue: 0.82)

        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                // Map thumbnail
                Group {
                    if let route {
                        RouteSnapshotView(route: route)
                    } else {
                        ZStack {
                            darkerSurface
                            Image(systemName: "map.fill")
                                .foregroundColor(darkText.opacity(0.25))
                                .font(.title)
                        }
                    }
                }
                .frame(width: 140, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(darkerSurface, lineWidth: 1))

                // Quest info
                VStack(alignment: .leading, spacing: 8) {
                    // Name row with rename button
                    HStack(spacing: 8) {
                        Text(quest.name)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(darkText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)

                        Button {
                            renameText = quest.name
                            renamingQuest = quest
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(darkText.opacity(0.35))
                                .padding(8)
                                .background(darkerSurface)
                                .clipShape(Circle())
                        }
                    }

                    if let route {
                        Text(route.name.uppercased())
                            .font(.system(size: 10, weight: .black))
                            .foregroundColor(darkText.opacity(0.40))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.top, 4)

                Spacer(minLength: 0)
            }
            .padding(14)

            // Progress bar
            if quest.totalItems > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(Int(progress * 100))% COMPLETE")
                            .font(.system(size: 10, weight: .black))
                            .foregroundColor(purple)
                        Spacer()
                        if quest.collectedItems > 0 {
                            Text("\(quest.collectedItems) / \(quest.totalItems)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(darkText.opacity(0.45))
                        }
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(darkerSurface)
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [purple, purple.opacity(0.6)],
                                    startPoint: .leading, endPoint: .trailing))
                                .frame(width: geo.size.width * CGFloat(progress))
                                .shadow(color: purple.opacity(0.18), radius: 3)
                        }
                    }
                    .frame(height: 5)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }

            // Action button
            questActionButton(quest, progress: progress)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
        .background(Color(red: 0.76, green: 0.78, blue: 0.88))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: Color(red: 0.01, green: 0.01, blue: 0.04), radius: 12, x: 6, y: 6)
        .shadow(color: Color(red: 0.14, green: 0.16, blue: 0.28).opacity(0.40), radius: 10, x: -4, y: -4)
    }

    // MARK: - Action Button

    private func questActionButton(_ quest: Quest, progress: Double) -> some View {
        let accent = Color(red: 0.45, green: 0.35, blue: 0.80)
        let (label, color1, color2): (String, Color, Color) = {
            if quest.isComplete            { return ("COMPLETED ✓",   Color(red: 0.68, green: 0.70, blue: 0.82), Color(red: 0.64, green: 0.66, blue: 0.78)) }
            if quest.collectedItems > 0    { return ("RESUME QUEST",  Color(red: 0.95, green: 0.55, blue: 0.25), Color(red: 0.85, green: 0.40, blue: 0.10)) }
            return ("START QUEST", accent, Color(red: 0.35, green: 0.25, blue: 0.70))
        }()

        return HStack {
            Text(label)
            if !quest.isComplete { Image(systemName: "chevron.right") }
        }
        .font(.system(size: 14, weight: .black))
        .kerning(1.2)
        .foregroundColor(quest.isComplete ? Color(red: 0.12, green: 0.13, blue: 0.20).opacity(0.50) : .white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            LinearGradient(colors: [color1, color2], startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: quest.isComplete ? .clear : color1.opacity(0.25), radius: 10, x: 0, y: 5)
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
                .foregroundColor(.white.opacity(0.50))
            Text("Record a route, then create a quest from the Routes tab.")
                .font(.body)
                .foregroundColor(.white.opacity(0.30))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
