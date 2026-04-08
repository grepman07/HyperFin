import SwiftUI
import SwiftData
import PhotosUI
import HFData
import HFIntelligence

struct ReceiptScanView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppDependencies.self) private var dependencies

    @Query(sort: \SDAccount.institutionName) private var accounts: [SDAccount]
    @Query(sort: \SDCategory.name) private var categories: [SDCategory]

    @State private var viewModel = ReceiptScanViewModel()

    let initialImage: UIImage?

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .selectingImage:
                    processingPlaceholder("Select a receipt image to scan")

                case .processing:
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Reading receipt...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .confirming, .saving:
                    confirmationForm

                case .saved:
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.green)
                        Text("Transaction Saved")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            dismiss()
                        }
                    }

                case .error(let message):
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Dismiss") { dismiss() }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Scan Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                viewModel.configure(inferenceEngine: dependencies.inferenceEngine)
                viewModel.modelContainer = modelContext.container
                if accounts.first != nil {
                    viewModel.selectedAccountId = accounts.first?.id
                }
                if let image = initialImage {
                    viewModel.processImage(image)
                }
            }
        }
    }

    private var confirmationForm: some View {
        Form {
            Section("Receipt Details") {
                TextField("Merchant Name", text: $viewModel.merchantName)
                TextField("Amount", text: $viewModel.amount)
                    .keyboardType(.decimalPad)
                DatePicker("Date", selection: $viewModel.date, displayedComponents: .date)
            }

            Section("Account") {
                if accounts.isEmpty {
                    Text("No accounts available. Link an account first.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Account", selection: $viewModel.selectedAccountId) {
                        ForEach(accounts) { account in
                            Text("\(account.institutionName) - \(account.accountName)")
                                .tag(Optional(account.id))
                        }
                    }
                }
            }

            Section("Category") {
                Picker("Category", selection: $viewModel.categoryId) {
                    Text("None").tag(UUID?.none)
                    ForEach(categories) { cat in
                        Label(cat.name, systemImage: cat.icon)
                            .tag(Optional(cat.id))
                    }
                }
            }

            Section("Notes") {
                TextField("Optional notes", text: $viewModel.notes, axis: .vertical)
                    .lineLimit(2...4)
            }

            Section {
                Button {
                    viewModel.saveTransaction()
                } label: {
                    HStack {
                        Spacer()
                        if viewModel.state == .saving {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Save Transaction")
                        }
                        Spacer()
                    }
                }
                .disabled(
                    viewModel.amount.isEmpty ||
                    viewModel.selectedAccountId == nil ||
                    viewModel.state == .saving
                )
                .listRowBackground(
                    (viewModel.amount.isEmpty || viewModel.selectedAccountId == nil)
                    ? Color.gray : Color.blue
                )
                .foregroundStyle(.white)
                .font(.headline)
            }
        }
    }

    private func processingPlaceholder(_ text: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Camera View Controller Representable

struct CameraView: UIViewControllerRepresentable {
    let onImageCaptured: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImageCaptured: onImageCaptured, dismiss: dismiss)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImageCaptured: (UIImage) -> Void
        let dismiss: DismissAction

        init(onImageCaptured: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onImageCaptured = onImageCaptured
            self.dismiss = dismiss
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onImageCaptured(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
