import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appSettings: AppSettings

    private let surface    = Color(red: 0.76, green: 0.78, blue: 0.88)
    private let deepSurf   = Color(red: 0.68, green: 0.70, blue: 0.82)
    private let darkText   = Color(red: 0.12, green: 0.13, blue: 0.20)
    private let shadowDark = Color(red: 0.01, green: 0.01, blue: 0.04)
    private let shadowLift = Color(red: 0.14, green: 0.16, blue: 0.28)
    private let teal       = Color(red: 0.18, green: 0.72, blue: 0.70)

    var body: some View {
        NavigationStack {
            ZStack {
                appBackground.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    Text("Settings")
                        .font(.system(size: 34, weight: .black))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 28)

                    ScrollView {
                        VStack(spacing: 16) {
                            sectionCard(title: "UNITS") {
                                unitsPicker
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 30)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Units Picker

    private var unitsPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(deepSurf)
                        .frame(width: 38, height: 38)
                        .shadow(color: shadowDark, radius: 4, x: 2, y: 2)
                    Image(systemName: "ruler")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(teal)
                }
                Text("Distance Units")
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundColor(darkText)
                Spacer()
            }

            HStack(spacing: 4) {
                unitButton("Miles", selected: !appSettings.useMetricUnits) {
                    appSettings.useMetricUnits = false
                }
                unitButton("Kilometers", selected: appSettings.useMetricUnits) {
                    appSettings.useMetricUnits = true
                }
            }
            .padding(4)
            .background(deepSurf)
            .clipShape(Capsule())
            .shadow(color: shadowDark, radius: 6, x: 3, y: 3)
            .shadow(color: shadowLift.opacity(0.35), radius: 4, x: -2, y: -2)
        }
    }

    private func unitButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(selected ? darkText : darkText.opacity(0.40))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(selected ? surface : Color.clear)
                .clipShape(Capsule())
        }
    }

    // MARK: - Section Card

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 11, weight: .black))
                .foregroundColor(darkText.opacity(0.40))
                .kerning(1.2)

            content()
        }
        .padding(18)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: shadowDark, radius: 12, x: 6, y: 6)
        .shadow(color: shadowLift.opacity(0.40), radius: 10, x: -4, y: -4)
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
}
