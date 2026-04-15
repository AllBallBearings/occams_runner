import SwiftUI

// MARK: - Neumorphic Card Helper

private extension View {
    func neuCard(cornerRadius: CGFloat = 20) -> some View {
        self
            .background(Color(red: 0.76, green: 0.78, blue: 0.88))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: Color(red: 0.01, green: 0.01, blue: 0.04), radius: 12, x: 6, y: 6)
            .shadow(color: Color(red: 0.14, green: 0.16, blue: 0.28).opacity(0.40), radius: 10, x: -4, y: -4)
    }
}

// MARK: - HomeView

struct HomeView: View {
    @EnvironmentObject var dataStore: DataStore
    @EnvironmentObject var appSettings: AppSettings

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
                VStack(spacing: 24) {
                    headerRow
                    heroStatSection
                    actionGrid
                    activeQuestBanner
                    recentActivitySection
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .background(appBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: Background

    private var appBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.07, blue: 0.18),  // midnight blue
                Color(red: 0.86, green: 0.88, blue: 0.94)   // white/lavender
            ],
            startPoint: .top, endPoint: .bottom)
    }

    // MARK: Header Row

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greetingText)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.40))
                Text("Runner")
                    .font(.title2).fontWeight(.bold)
                    .foregroundColor(.white)
            }

            Spacer()

            // Level badge — lavender surface with dark text
            Text("Lv \(userLevel)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.20))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color(red: 0.76, green: 0.78, blue: 0.88))
                .clipShape(Capsule())
                .shadow(color: Color(red: 0.01, green: 0.01, blue: 0.04), radius: 4, x: 2, y: 2)

            // Avatar — lavender circle
            ZStack {
                Circle()
                    .fill(Color(red: 0.72, green: 0.74, blue: 0.86))
                Image(systemName: "person.fill")
                    .font(.system(size: 20))
                    .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.20).opacity(0.70))
            }
            .frame(width: 44, height: 44)
            .shadow(color: Color(red: 0.01, green: 0.01, blue: 0.04), radius: 6, x: 3, y: 3)
        }
        .padding(.top, 8)
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning," }
        if hour < 17 { return "Good afternoon," }
        return "Good evening,"
    }

    // MARK: Hero Stat Section

    private var heroStatSection: some View {
        let progress = min(1.0, todayDistanceMeters / dailyGoalMeters)
        let displayValue = appSettings.distanceValue(meters: todayDistanceMeters)
        let unitLabel = appSettings.distanceUnitLabel + " today"

        return ZStack {
            // Ring track
            Circle()
                .stroke(Color(red: 0.76, green: 0.78, blue: 0.88).opacity(0.10), lineWidth: 14)
            // Progress arc — indigo gradient
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    LinearGradient(
                        colors: [Color(red: 0.18, green: 0.72, blue: 0.70),
                                 Color(red: 0.10, green: 0.50, blue: 0.75)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: Color(red: 0.18, green: 0.72, blue: 0.70).opacity(0.30), radius: 10)
                .animation(.spring(response: 0.6, dampingFraction: 0.7), value: progress)

            // Center stat — white text floats on dark bg inside ring
            VStack(spacing: 2) {
                Text(String(format: "%.1f", displayValue))
                    .font(.system(size: 52, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                Text(unitLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.35))
                    .kerning(0.5)
                // XP on lavender pill
                HStack(spacing: 4) {
                    Text("\(totalXP)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.20))
                    Text("XP")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.20).opacity(0.55))
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color(red: 0.76, green: 0.78, blue: 0.88))
                .clipShape(Capsule())
                .shadow(color: Color(red: 0.01, green: 0.01, blue: 0.04), radius: 4, x: 2, y: 2)
                .padding(.top, 4)
            }
        }
        .frame(width: 210, height: 210)
        .padding(.vertical, 8)
    }

    // MARK: Action Grid

    private let actionGridColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    private var actionGrid: some View {
        LazyVGrid(columns: actionGridColumns, spacing: 16) {
            actionCircleButton(
                icon: "arrow.triangle.swap", label: "Record",
                iconColor: Color(red: 0.95, green: 0.55, blue: 0.25),
                destination: AnyView(RecordRunView()))
            actionCircleButton(
                icon: "safari", label: "Quests",
                iconColor: Color(red: 0.45, green: 0.35, blue: 0.80),
                destination: AnyView(QuestsListView()))
            actionCircleButton(
                icon: "map", label: "Routes",
                iconColor: Color(red: 0.18, green: 0.72, blue: 0.70),
                destination: AnyView(RoutesListView()))
            actionCircleButton(
                icon: "person.fill", label: "Profile",
                iconColor: Color(red: 0.35, green: 0.75, blue: 0.50),
                destination: AnyView(ProfileView()))
        }
    }

    private func actionCircleButton(icon: String, label: String, iconColor: Color, destination: AnyView) -> some View {
        NavigationLink(destination: destination) {
            VStack(spacing: 10) {
                // Icon circle — darker lavender inset (recessed look)
                ZStack {
                    Circle()
                        .fill(Color(red: 0.68, green: 0.70, blue: 0.82))
                        .frame(width: 60, height: 60)
                        .shadow(color: Color(red: 0.01, green: 0.01, blue: 0.04), radius: 6, x: 3, y: 3)
                        .shadow(color: Color(red: 0.14, green: 0.16, blue: 0.28).opacity(0.35), radius: 5, x: -2, y: -2)
                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(iconColor)
                }
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.20).opacity(0.70))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(Color(red: 0.76, green: 0.78, blue: 0.88))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: Color(red: 0.01, green: 0.01, blue: 0.04), radius: 10, x: 5, y: 5)
            .shadow(color: Color(red: 0.14, green: 0.16, blue: 0.28).opacity(0.40), radius: 8, x: -3, y: -3)
        }
        .buttonStyle(.plain)
    }

    // MARK: Active Quest Banner

    @ViewBuilder
    private var activeQuestBanner: some View {
        if let quest = activeQuest {
            let accent = Color(red: 0.45, green: 0.35, blue: 0.80)
            let progress = quest.totalItems > 0
                ? Double(quest.collectedItems) / Double(quest.totalItems) : 0.0

            NavigationLink(destination: QuestDetailView(quest: quest)) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.68, green: 0.70, blue: 0.82))
                            .frame(width: 44, height: 44)
                            .shadow(color: Color(red: 0.01, green: 0.01, blue: 0.04), radius: 4, x: 2, y: 2)
                        Image(systemName: "star.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(accent)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("ACTIVE QUEST")
                            .font(.system(size: 9, weight: .black))
                            .foregroundColor(accent.opacity(0.80))
                            .kerning(0.8)
                        Text(quest.name)
                            .font(.subheadline).fontWeight(.semibold)
                            .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.20))
                            .lineLimit(1)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color(red: 0.68, green: 0.70, blue: 0.82))
                                Capsule()
                                    .fill(LinearGradient(
                                        colors: [Color(red: 0.18, green: 0.72, blue: 0.70), accent],
                                        startPoint: .leading, endPoint: .trailing))
                                    .frame(width: geo.size.width * progress)
                            }
                        }
                        .frame(height: 4)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(accent)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.20).opacity(0.30))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color(red: 0.76, green: 0.78, blue: 0.88))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .shadow(color: Color(red: 0.01, green: 0.01, blue: 0.04), radius: 10, x: 5, y: 5)
                .shadow(color: Color(red: 0.14, green: 0.16, blue: 0.28).opacity(0.40), radius: 8, x: -3, y: -3)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Recent Activity

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recent Activity")
                .font(.headline).fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.horizontal, 4)

            if recentActivity.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "figure.run.circle")
                        .font(.system(size: 40))
                        .foregroundColor(.white.opacity(0.15))
                    Text("No runs yet. Start your first quest!")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.35))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .background(Color(red: 0.76, green: 0.78, blue: 0.88).opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 20))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recentActivity.enumerated()), id: \.element.session.id) { index, item in
                        if index > 0 {
                            Divider()
                                .background(Color(red: 0.68, green: 0.70, blue: 0.82))
                                .padding(.horizontal, 16)
                        }
                        activityRow(
                            date: item.session.startTime,
                            distanceMeters: item.distanceMeters,
                            points: item.quest.collectedPoints,
                            isFirst: index == 0)
                    }
                }
                .background(Color(red: 0.76, green: 0.78, blue: 0.88))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: Color(red: 0.01, green: 0.01, blue: 0.04), radius: 12, x: 6, y: 6)
                .shadow(color: Color(red: 0.14, green: 0.16, blue: 0.28).opacity(0.40), radius: 10, x: -4, y: -4)
            }
        }
    }

    private func activityRow(date: Date, distanceMeters: Double, points: Int, isFirst: Bool) -> some View {
        HStack {
            ZStack {
                Circle()
                    .fill(Color(red: 0.68, green: 0.70, blue: 0.82))
                    .frame(width: 40, height: 40)
                    .shadow(color: Color(red: 0.01, green: 0.01, blue: 0.04), radius: 3, x: 2, y: 2)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Color(red: 0.18, green: 0.72, blue: 0.70))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(relativeDay(date))
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.20))
                Text(appSettings.formatDistanceShort(meters: distanceMeters) + " Run")
                    .font(.caption)
                    .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.20).opacity(0.50))
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color(red: 0.75, green: 0.60, blue: 0.20))
                Text("+\(points)")
                    .font(.subheadline).fontWeight(.bold)
                    .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.20))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(red: 0.68, green: 0.70, blue: 0.82))
            .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
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
