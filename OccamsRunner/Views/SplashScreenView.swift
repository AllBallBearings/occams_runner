import SwiftUI

struct SplashScreenView: View {
    @Binding var isShowing: Bool

    @State private var opacity: Double = 1.0
    @State private var logoScale: Double = 0.85

    var body: some View {
        ZStack {
            Color(red: 0.063, green: 0.071, blue: 0.098)
                .ignoresSafeArea()

            Image("SplashImage")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .scaleEffect(logoScale)
        }
        .opacity(opacity)
        .onAppear {
            // Brief pop-in on the image
            withAnimation(.easeOut(duration: 0.4)) {
                logoScale = 1.0
            }
            // Hold for 1.6s then fade out
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation(.easeIn(duration: 0.5)) {
                    opacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isShowing = false
                }
            }
        }
    }
}
