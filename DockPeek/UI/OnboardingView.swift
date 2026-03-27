import SwiftUI

struct OnboardingView: View {
    let onDismiss: () -> Void
    @State private var isChecking = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "hand.raised.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text(L10n.onboardingTitle)
                .font(.headline)

            Text(L10n.onboardingBody)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                stepRow(1, L10n.onboardingStep1)
                stepRow(2, L10n.onboardingStep2)
                stepRow(3, L10n.onboardingStep3)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))

            HStack(spacing: 12) {
                Button(L10n.onboardingOpenSettings) {
                    AccessibilityManager.shared.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)

                Button(L10n.onboardingConfirm) {
                    isChecking = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        isChecking = false
                        if AccessibilityManager.shared.isAccessibilityGranted { onDismiss() }
                    }
                }
                .disabled(isChecking)
            }

            if isChecking { ProgressView().scaleEffect(0.8) }
        }
        .padding(32)
        .frame(width: 400)
    }

    private func stepRow(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n).").font(.body.bold()).frame(width: 24)
            Text(text).font(.body)
        }
    }
}
