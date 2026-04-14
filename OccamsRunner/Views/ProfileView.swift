import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var dataStore: DataStore

    // Design constants
    private let surface    = Color(red: 0.76, green: 0.78, blue: 0.88)
    private let deepSurf   = Color(red: 0.68, green: 0.70, blue: 0.82)
    private let darkText   = Color(red: 0.12, green: 0.13, blue: 0.20)
    private let teal       = Color(red: 0.18, green: 0.72, blue: 0.70)
    private let indigo     = Color(red: 0.45, green: 0.35, blue: 0.80)
    private let shadowDark = Color(red: 0.01, green: 0.01, blue: 0.04)
    private let shadowLift = Color(red: 0.14, green: 0.16, blue: 0.28)

    private var totalXP: Int {
        dataStore.quests.reduce(0) { $0 + $1.collectedPoints }
    }
    private var userLevel: Int { max(1, totalXP / 1000 + 1) }
    private var xpInLevel: Int { totalXP % 1000 }
    private var totalRoutesRecorded: Int  { dataStore.routes.count }
    private var totalQuestsCreated: Int   { dataStore.quests.count }
    private var totalQuestsCompleted: Int { dataStore.quests.filter { $0.isComplete }.count }
    private var totalCoinsCollected: Int  { dataStore.quests.reduce(0) { $0 + $1.collectedItems } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    avatarSection
                    xpCard
                    statsGrid
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(appBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Background

    private var appBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.07, blue: 0.18),
                Color(red: 0.86, green: 0.88, blue: 0.94)
            ],
            startPoint: .top, endPoint: .bottom)
    }

    // MARK: - Avatar Section

    private var avatarSection: some View {
        VStack(spacing: 16) {
            // Avatar circle — neumorphic
            ZStack {
                Circle()
                    .fill(deepSurf)
                    .frame(width: 100, height: 100)
                    .shadow(color: shadowDark, radius: 14, x: 7, y: 7)
                    .shadow(color: shadowLift.opacity(0.40), radius: 10, x: -4, y: -4)

                Image(systemName: "person.fill")
                    .font(.system(size: 46))
                    .foregroundColor(darkText.opacity(0.55))
            }
            // Teal ring around avatar
            .overlay(
                Circle().stroke(
                    LinearGradient(
                        colors: [teal, indigo],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 2.5)
            )

            VStack(spacing: 4) {
                Text("Runner")
                    .font(.title2).fontWeight(.bold)
                    .foregroundColor(.white)

                // Level badge
                HStack(spacing: 6) {
                    Text("Level \(userLevel)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(darkText)
                    Text("·")
                        .foregroundColor(darkText.opacity(0.35))
                    Text("\(totalXP) XP")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(teal)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(surface)
                .clipShape(Capsule())
                .shadow(color: shadowDark, radius: 6, x: 3, y: 3)
                .shadow(color: shadowLift.opacity(0.35), radius: 4, x: -2, y: -2)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - XP Progress Card

    private var xpCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Level \(userLevel) Progress")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(darkText.opacity(0.55))
                Spacer()
                Text("\(xpInLevel) / 1000 XP")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(teal)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(deepSurf)
                    Capsule()
                        .fill(LinearGradient(
                            colors: [teal, indigo],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(xpInLevel) / 1000.0)
                        .shadow(color: teal.opacity(0.25), radius: 4)
                }
            }
            .frame(height: 8)
        }
        .padding(18)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: shadowDark, radius: 12, x: 6, y: 6)
        .shadow(color: shadowLift.opacity(0.40), radius: 10, x: -4, y: -4)
    }

    // MARK: - Stats Grid

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
            statCard(value: "\(totalRoutesRecorded)", label: "Routes\nRecorded",
                     icon: "map.fill", color: Color(red: 0.95, green: 0.55, blue: 0.25))
            statCard(value: "\(totalQuestsCreated)", label: "Quests\nCreated",
                     icon: "safari", color: teal)
            statCard(value: "\(totalQuestsCompleted)", label: "Quests\nCompleted",
                     icon: "checkmark.seal.fill", color: indigo)
            statCard(value: "\(totalCoinsCollected)", label: "Coins\nCollected",
                     icon: "circle.fill", color: Color(red: 0.75, green: 0.60, blue: 0.20))
        }
    }

    private func statCard(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 10) {
            // Icon circle
            ZStack {
                Circle().fill(deepSurf).frame(width: 44, height: 44)
                    .shadow(color: shadowDark, radius: 5, x: 3, y: 3)
                    .shadow(color: shadowLift.opacity(0.35), radius: 4, x: -2, y: -2)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(color)
            }

            Text(value)
                .font(.system(size: 32, weight: .black, design: .rounded))
                .foregroundColor(darkText)

            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(darkText.opacity(0.45))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: shadowDark, radius: 12, x: 6, y: 6)
        .shadow(color: shadowLift.opacity(0.40), radius: 10, x: -4, y: -4)
    }
}
