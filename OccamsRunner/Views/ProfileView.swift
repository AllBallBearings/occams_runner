import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var dataStore: DataStore

    private var totalXP: Int {
        dataStore.quests.reduce(0) { $0 + $1.collectedPoints }
    }

    private var userLevel: Int {
        max(1, totalXP / 1000 + 1)
    }

    private var totalRoutesRecorded: Int { dataStore.routes.count }
    private var totalQuestsCreated: Int  { dataStore.quests.count }
    private var totalQuestsCompleted: Int { dataStore.quests.filter { $0.isComplete }.count }
    private var totalCoinsCollected: Int {
        dataStore.quests.reduce(0) { $0 + $1.collectedItems }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Avatar + name
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color(red: 0.15, green: 0.17, blue: 0.25))
                            Image(systemName: "person.fill")
                                .font(.system(size: 52))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .frame(width: 100, height: 100)
                        .overlay(
                            Circle().stroke(
                                LinearGradient(
                                    colors: [.cyan, Color(red: 0.6, green: 0.2, blue: 1.0)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 2))
                        .shadow(color: .cyan.opacity(0.3), radius: 12)

                        Text("Runner")
                            .font(.title2).fontWeight(.bold)
                            .foregroundColor(.white)

                        Text("Level \(userLevel) · \(totalXP) XP")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.top, 8)

                    // Stats grid
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        statCard(value: "\(totalRoutesRecorded)", label: "Routes Recorded", color: .orange)
                        statCard(value: "\(totalQuestsCreated)", label: "Quests Created", color: .cyan)
                        statCard(value: "\(totalQuestsCompleted)", label: "Quests Completed", color: Color(red: 0.6, green: 0.2, blue: 1.0))
                        statCard(value: "\(totalCoinsCollected)", label: "Coins Collected", color: .yellow)
                    }
                    .padding(.horizontal, 16)

                    Spacer(minLength: 40)
                }
            }
            .background(Color(red: 0.063, green: 0.071, blue: 0.098).ignoresSafeArea())
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private func statCard(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.largeTitle).fontWeight(.bold)
                .foregroundColor(color)
                .shadow(color: color.opacity(0.6), radius: 4)
            Text(label)
                .font(.caption)
                .foregroundColor(.white.opacity(0.65))
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.1, green: 0.11, blue: 0.16))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(color.opacity(0.45), lineWidth: 1))
        .shadow(color: color.opacity(0.25), radius: 6)
    }
}
