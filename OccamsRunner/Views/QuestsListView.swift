import SwiftUI

struct QuestsListView: View {
    @EnvironmentObject var dataStore: DataStore

    var body: some View {
        NavigationView {
            Group {
                if dataStore.quests.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "star.circle")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        Text("No Quests Yet")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Record a route first, then create a quest from the route detail page.")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } else {
                    List {
                        ForEach(dataStore.quests.sorted(by: { $0.dateCreated > $1.dateCreated })) { quest in
                            NavigationLink(destination: QuestDetailView(quest: quest)) {
                                questRow(quest)
                            }
                        }
                        .onDelete(perform: deleteQuests)
                    }
                }
            }
            .navigationTitle("My Quests")
        }
    }

    private func questRow(_ quest: Quest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(quest.name)
                .font(.headline)

            HStack(spacing: 16) {
                Label("\(quest.totalItems) coins", systemImage: "circle.circle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)

                Label("\(quest.totalPoints) pts", systemImage: "star.fill")
                    .font(.caption)
                    .foregroundColor(.yellow)

                if quest.collectedItems > 0 {
                    Text("\(quest.collectedItems)/\(quest.totalItems) collected")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            // Progress bar
            if quest.totalItems > 0 {
                ProgressView(value: Double(quest.collectedItems), total: Double(quest.totalItems))
                    .tint(.orange)
            }

            Text(quest.dateCreated, style: .date)
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .padding(.vertical, 4)
    }

    private func deleteQuests(at offsets: IndexSet) {
        let sorted = dataStore.quests.sorted(by: { $0.dateCreated > $1.dateCreated })
        for index in offsets {
            dataStore.deleteQuest(sorted[index])
        }
    }
}
