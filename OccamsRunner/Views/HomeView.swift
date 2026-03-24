import SwiftUI

// MARK: - Neon Card Helper

private extension View {
    func neonCard(color: Color, cornerRadius: CGFloat = 16) -> some View {
        self
            .background(Color(red: 0.1, green: 0.11, blue: 0.16))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(color, lineWidth: 1.5)
            )
            .shadow(color: color.opacity(0.5), radius: 10, x: 0, y: 0)
    }
}

// MARK: - HomeView

struct HomeView: View {
    @EnvironmentObject var dataStore: DataStore

    // MARK: Computed user data

    private var totalXP: Int {
        dataStore.quests.reduce(0) { $0 + $1.collectedPoints }
    }

    private var userLevel: Int {
        max(1, totalXP / 1000 + 1)
    }

    private var xpInCurrentLevel: Int {
        totalXP % 1000
    }

    private let xpPerLevel = 1000

    // Most-recent incomplete quest that has at least some progress, or just the newest incomplete quest
    private var activeQuest: Quest? {
        let incomplete = dataStore.quests.filter { !$0.isComplete }
        return incomplete.filter { $0.collectedItems > 0 }.sorted { $0.dateCreated > $1.dateCreated }.first
            ?? incomplete.sorted { $0.dateCreated > $1.dateCreated }.first
    }

    private var todayDistanceMeters: Double {
        let calendar = Calendar.current
        let questIds = Set(
            dataStore.runSessions
                .filter { calendar.isDateInToday($0.startTime) }
                .map { $0.questId }
        )
        return questIds.compactMap { questId -> Double? in
            guard let quest = dataStore.quests.first(where: { $0.id == questId }),
                  let route = dataStore.routes.first(where: { $0.id == quest.routeId })
            else { return nil }
            return route.totalDistanceMeters
        }.reduce(0, +)
    }

    private let dailyGoalMeters: Double = 5000

    private var recentActivity: [(session: RunSession, quest: Quest, distanceMeters: Double)] {
        dataStore.runSessions
            .sorted { $0.startTime > $1.startTime }
            .prefix(5)
            .compactMap { session -> (RunSession, Quest, Double)? in
                guard let quest = dataStore.quests.first(where: { $0.id == session.questId }),
                      let route = dataStore.routes.first(where: { $0.id == quest.routeId })
                else { return nil }
                return (session, quest, route.totalDistanceMeters)
            }
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    profileCard
                    actionCardsSection
                    dailyGoalCard
                    recentActivitySection
                }
                .padding(16)
            }
            .background(appBackground.ignoresSafeArea())
            .navigationTitle("Dashboard Home")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private var appBackground: Color {
        Color(red: 0.063, green: 0.071, blue: 0.098)
    }

    private var cardBackground: Color {
        Color(red: 0.1, green: 0.11, blue: 0.16)
    }

    // MARK: Profile Card

    private var profileCard: some View {
        HStack(spacing: 14) {
            // Avatar placeholder
            ZStack {
                Circle()
                    .fill(Color(red: 0.2, green: 0.22, blue: 0.3))
                Image(systemName: "person.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white.opacity(0.55))
            }
            .frame(width: 56, height: 56)
            .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Runner")
                        .font(.title3).fontWeight(.bold)
                        .foregroundColor(.white)
                    Text("Level \(userLevel)")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color(red: 0.45, green: 0.12, blue: 0.85))
                        .clipShape(Capsule())
                }

                // XP progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(LinearGradient(
                                colors: [Color(red: 0.2, green: 0.5, blue: 1.0),
                                         Color(red: 0.65, green: 0.25, blue: 1.0)],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * CGFloat(xpInCurrentLevel) / CGFloat(xpPerLevel))
                    }
                    .frame(height: 8)
                }
                .frame(height: 8)
            }

            Spacer()

            Text("XP: \(totalXP) / \(userLevel * xpPerLevel)")
                .font(.caption)
                .foregroundColor(.white.opacity(0.75))
        }
        .padding(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    LinearGradient(
                        colors: [.cyan, Color(red: 0.6, green: 0.2, blue: 1.0)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1.5)
        )
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.cyan.opacity(0.25), radius: 12, x: 0, y: 0)
    }

    // MARK: Action Cards

    private var actionCardsSection: some View {
        HStack(alignment: .top, spacing: 12) {
            recordRouteCard
            planQuestCard
            activeQuestCard
        }
        .frame(minHeight: 200)
    }

    private var recordRouteCard: some View {
        NavigationLink(destination: RecordRunView()) {
            VStack(spacing: 10) {
                Image(systemName: "arrow.triangle.swap")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundColor(.orange)
                    .shadow(color: .orange.opacity(0.9), radius: 8)
                    .padding(.top, 4)

                Text("Record New Route")
                    .font(.caption).fontWeight(.bold)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Text("Map your run and collect AR coins.")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.55))
                    .multilineTextAlignment(.center)

                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .neonCard(color: .orange)
        }
        .buttonStyle(.plain)
    }

    private var planQuestCard: some View {
        NavigationLink(destination: RoutesListView()) {
            VStack(spacing: 10) {
                Image(systemName: "safari")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundColor(.cyan)
                    .shadow(color: .cyan.opacity(0.9), radius: 8)
                    .padding(.top, 4)

                Text("Plan a Quest")
                    .font(.caption).fontWeight(.bold)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Text("Set challenges and unlock rewards.")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.55))
                    .multilineTextAlignment(.center)

                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .neonCard(color: .cyan)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var activeQuestCard: some View {
        let purple = Color(red: 0.6, green: 0.2, blue: 1.0)
        if let quest = activeQuest {
            let progress = quest.totalItems > 0
                ? Double(quest.collectedItems) / Double(quest.totalItems) : 0.0

            NavigationLink(destination: QuestDetailView(quest: quest)) {
                VStack(alignment: .leading, spacing: 8) {
                    // Mini map placeholder
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(red: 0.14, green: 0.18, blue: 0.28))
                        Image(systemName: "map.fill")
                            .font(.system(size: 22))
                            .foregroundColor(Color(red: 0.45, green: 0.6, blue: 0.85))
                    }
                    .frame(height: 60)

                    Text(quest.name)
                        .font(.caption).fontWeight(.bold)
                        .foregroundColor(.white)
                        .lineLimit(2)

                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12))
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [.blue, purple],
                                    startPoint: .leading, endPoint: .trailing))
                                .frame(width: geo.size.width * progress)
                        }
                        .frame(height: 4)
                    }
                    .frame(height: 4)

                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.65))

                    Spacer()

                    Text("Resume")
                        .font(.caption2).fontWeight(.semibold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(purple)
                        .clipShape(Capsule())
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .neonCard(color: purple)
            }
            .buttonStyle(.plain)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "star.circle")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundColor(purple)
                    .shadow(color: purple.opacity(0.9), radius: 8)
                    .padding(.top, 4)

                Text("No Active Quest")
                    .font(.caption).fontWeight(.bold)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Text("Create a quest to track it here.")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.55))
                    .multilineTextAlignment(.center)

                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .neonCard(color: purple)
        }
    }

    // MARK: Daily Goal Card

    private var dailyGoalCard: some View {
        let progress = min(1.0, todayDistanceMeters / dailyGoalMeters)
        let todayKm  = todayDistanceMeters / 1000.0
        let goalKm   = dailyGoalMeters / 1000.0

        return HStack(spacing: 20) {
            // Circular ring
            ZStack {
                Circle()
                    .stroke(Color.green.opacity(0.18), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: .green.opacity(0.6), radius: 5)
            }
            .frame(width: 84, height: 84)
            .animation(.easeOut(duration: 0.6), value: progress)

            VStack(alignment: .leading, spacing: 4) {
                Text("Daily Goal: \(String(format: "%.0f", goalKm))km")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.white)

                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", todayKm) + "km")
                        .font(.title2).fontWeight(.bold)
                        .foregroundColor(.white)
                    Text("/ \(String(format: "%.0f", goalKm))km")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.45))
                }

                Text(progress >= 1.0 ? "Goal complete! Great work!" : "Keep going!")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.65))
            }

            Spacer()
        }
        .padding(20)
        .neonCard(color: .green)
    }

    // MARK: Recent Activity

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Activity")
                .font(.headline).fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.horizontal, 4)

            if recentActivity.isEmpty {
                Text("No activity yet. Complete a quest to see your history here.")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .multilineTextAlignment(.center)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recentActivity.enumerated()), id: \.element.session.id) { index, item in
                        if index > 0 {
                            Divider()
                                .background(Color.white.opacity(0.08))
                        }
                        activityRow(
                            date: item.session.startTime,
                            distanceMeters: item.distanceMeters,
                            points: item.quest.collectedPoints,
                            isFirst: index == 0)
                    }
                }
                .background(cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1))
            }
        }
    }

    private func activityRow(date: Date, distanceMeters: Double, points: Int, isFirst: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(relativeDay(date))
                    .font(.subheadline)
                    .foregroundColor(.white)
                Text(String(format: "%.1f", distanceMeters / 1000.0) + "km Run")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.55))
            }

            Spacer()

            HStack(spacing: 5) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.yellow)
                Text("+\(points) Coins")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(isFirst ? .yellow : .green)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: Helpers

    private func relativeDay(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date)     { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE"
        return fmt.string(from: date)
    }
}
