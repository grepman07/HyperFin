import SwiftUI
import SwiftData
import HFData
import HFDomain
import HFShared

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @Environment(\.modelContext) private var modelContext
    @State private var currentStep = 0
    @State private var telemetryOptIn = false // default OFF
    @State private var showLearnMore = false
    @State private var cloudChatOptIn = false // default OFF — opt-in cloud tier
    @State private var showCloudLearnMore = false

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

    // Two consent pages appended after the core steps:
    //  index steps.count     → telemetry consent
    //  index steps.count + 1 → cloud chat consent
    private var totalStepCount: Int { steps.count + 2 }
    private var isOnTelemetryStep: Bool { currentStep == steps.count }
    private var isOnCloudChatStep: Bool { currentStep == steps.count + 1 }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $currentStep) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    stepView(step)
                        .tag(index)
                }

                telemetryConsentView
                    .tag(steps.count)

                cloudChatConsentView
                    .tag(steps.count + 1)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button {
                if currentStep < totalStepCount - 1 {
                    withAnimation { currentStep += 1 }
                } else {
                    finishOnboarding()
                }
            } label: {
                Text(currentStep < totalStepCount - 1 ? "Next" : "Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            if currentStep < totalStepCount - 1 {
                Button("Skip") { finishOnboarding() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)
            } else {
                Spacer().frame(height: 48)
            }
        }
        .sheet(isPresented: $showLearnMore) {
            TelemetryLearnMoreSheet()
        }
        .sheet(isPresented: $showCloudLearnMore) {
            CloudChatLearnMoreSheet()
        }
    }

    private func stepView(_ step: OnboardingStep) -> some View {
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
    }

    private var telemetryConsentView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 70))
                .foregroundStyle(.blue)
                .padding(.bottom, 8)
            Text("Help Improve HyperFin")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text("Share anonymized chats and ratings so we can improve the AI. Your name, email, and account numbers are stripped on-device before anything leaves your phone.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Toggle(isOn: $telemetryOptIn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share anonymized chats")
                        .font(.body.weight(.medium))
                    Text("You can change this anytime in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24)

            Button("Learn what's shared") { showLearnMore = true }
                .font(.subheadline)
                .foregroundStyle(.blue)

            Spacer()
        }
    }

    private var cloudChatConsentView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "cloud.fill")
                .font(.system(size: 70))
                .foregroundStyle(.blue)
                .padding(.bottom, 8)
            Text("Smarter Answers (Optional)")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text("Use Anthropic's Claude Haiku for chat replies — it writes noticeably better explanations than the on-device model. Your transactions stay on your iPhone. Only your question and the totals we compute from it are sent.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Toggle(isOn: $cloudChatOptIn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use cloud chat")
                        .font(.body.weight(.medium))
                    Text("You can change this anytime in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24)

            Button("Learn what's shared") { showCloudLearnMore = true }
                .font(.subheadline)
                .foregroundStyle(.blue)

            Spacer()
        }
    }

    private func finishOnboarding() {
        let ctx = modelContext
        let existing = try? ctx.fetch(FetchDescriptor<SDUserProfile>()).first
        let now = Date()
        if let existing {
            existing.onboardingCompleted = true
            existing.telemetryOptIn = telemetryOptIn
            existing.telemetryOptInDate = telemetryOptIn ? now : nil
            existing.cloudChatOptIn = cloudChatOptIn
            existing.cloudChatOptInDate = cloudChatOptIn ? now : nil
        } else {
            let profile = UserProfile(
                onboardingCompleted: true,
                telemetryOptIn: telemetryOptIn,
                telemetryOptInDate: telemetryOptIn ? now : nil,
                cloudChatOptIn: cloudChatOptIn,
                cloudChatOptInDate: cloudChatOptIn ? now : nil
            )
            ctx.insert(SDUserProfile(from: profile))
        }
        try? ctx.save()
        HFLogger.telemetry.info("Onboarding completed. telemetryOptIn=\(telemetryOptIn) cloudChatOptIn=\(cloudChatOptIn)")
        isComplete = true
    }
}

private struct OnboardingStep {
    let icon: String
    let title: String
    let description: String
}

private struct TelemetryLearnMoreSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("What we collect", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.blue)

                    Text("• The questions you ask (anonymized)\n• The AI's answers (anonymized)\n• Your thumbs up / thumbs down ratings\n• Response timing and the model version\n• A random install ID — NOT your email or account")
                        .font(.callout)

                    Divider()

                    Label("What we strip out", systemImage: "xmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.red)

                    Text("• Your name\n• Email addresses\n• Account numbers (last-4 and full)\n• Social security numbers\n• Plaid institution tokens")
                        .font(.callout)

                    Divider()

                    Label("Example", systemImage: "text.bubble.fill")
                        .font(.headline)

                    Text("Raw:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\"How much did Kevin spend at Uber on card ****1234?\"")
                        .font(.callout)
                        .padding(10)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text("Uploaded:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\"How much did [NAME] spend at Uber on card [ACCT]?\"")
                        .font(.callout)
                        .padding(10)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding()
            }
            .navigationTitle("What's shared")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct CloudChatLearnMoreSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("How cloud chat works", systemImage: "cloud.fill")
                        .font(.headline)
                        .foregroundStyle(.blue)

                    Text("Your transactions are read and summarized on your iPhone — HyperFin never uploads individual transaction rows. When you opt in, we send your question and the computed totals to Claude Haiku, which writes the reply.")
                        .font(.callout)

                    Divider()

                    Label("What is sent", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.blue)

                    Text("• Your question (with your name stripped out)\n• Pre-computed totals such as \"$142.50 spent on Food & Dining this month\"\n• The top 5 merchants by amount for the period\n• A random install ID for rate limiting")
                        .font(.callout)

                    Divider()

                    Label("What is NOT sent", systemImage: "xmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.red)

                    Text("• Individual transaction rows\n• Merchant descriptions or memos\n• Account numbers (full or last-4)\n• Your name or email\n• Plaid access tokens\n• Balances you didn't ask about")
                        .font(.callout)

                    Divider()

                    Label("Your control", systemImage: "hand.raised.fill")
                        .font(.headline)
                        .foregroundStyle(.blue)

                    Text("You can turn cloud chat off at any time in Settings. When off, replies are generated entirely on your iPhone.")
                        .font(.callout)
                }
                .padding()
            }
            .navigationTitle("What's shared")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
