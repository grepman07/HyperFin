import SwiftUI

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var currentStep = 0

    private let steps: [OnboardingStep] = [
        OnboardingStep(
            icon: "brain.head.profile.fill",
            title: "AI That Lives on Your Device",
            description: "HyperFin's AI runs entirely on your iPhone. Your financial data never leaves your device — it's a structural guarantee, not just a privacy policy."
        ),
        OnboardingStep(
            icon: "message.fill",
            title: "Just Ask",
            description: "\"How much did I spend on food this month?\" Ask in plain English and get instant answers. No more digging through transaction lists."
        ),
        OnboardingStep(
            icon: "bell.badge.fill",
            title: "Stay Ahead of Your Money",
            description: "Get proactive alerts before you overspend. HyperFin watches your budget and warns you before problems happen — not after."
        ),
        OnboardingStep(
            icon: "wand.and.stars",
            title: "Automatic Budgets",
            description: "Connect your bank and HyperFin analyzes your spending to create a personalized budget. No manual setup required."
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $currentStep) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    VStack(spacing: 24) {
                        Spacer()

                        Image(systemName: step.icon)
                            .font(.system(size: 70))
                            .foregroundStyle(.blue)
                            .padding(.bottom, 8)

                        Text(step.title)
                            .font(.title.bold())
                            .multilineTextAlignment(.center)

                        Text(step.description)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)

                        Spacer()
                        Spacer()
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button {
                if currentStep < steps.count - 1 {
                    withAnimation { currentStep += 1 }
                } else {
                    isComplete = true
                }
            } label: {
                Text(currentStep < steps.count - 1 ? "Next" : "Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            if currentStep < steps.count - 1 {
                Button("Skip") { isComplete = true }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)
            } else {
                Spacer().frame(height: 48)
            }
        }
    }
}

private struct OnboardingStep {
    let icon: String
    let title: String
    let description: String
}
