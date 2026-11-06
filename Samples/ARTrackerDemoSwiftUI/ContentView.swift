import SwiftUI
import ARTracker

struct ContentView: View {
    @State private var metricsText: String = "No metrics yet"
    @State private var navigateToCheckout: Bool = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    Group {
                        Text("ARTracker iOS Demo")
                            .font(.largeTitle)
                            .bold()

                        Text("Screen 1: Dashboard & Telemetry")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    // Navigation to Screen 2
                    NavigationLink(destination: CheckoutDetailView(), isActive: $navigateToCheckout) {
                        EmptyView()
                    }

                    Button(action: {
                        ARTracker.breadcrumb("Navigating to Checkout Screen", category: "navigation", type: "navigation")
                        navigateToCheckout = true
                    }) {
                        HStack {
                            Image(systemName: "cart.fill")
                            Text("Open Screen 2 (Checkout & Replay)")
                                .fontWeight(.semibold)
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .padding(.horizontal)

                    // Live Metrics Card
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Live SDK Metrics")
                                .font(.headline)
                            Spacer()
                            Button("Refresh") {
                                refreshMetrics()
                            }
                            .font(.caption)
                        }
                        Text(metricsText)
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(8)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)

                    // Action Controls
                    VStack(spacing: 12) {
                        Button(action: sendManualEvent) {
                            Label("Send Custom Event", systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button(action: recordBreadcrumb) {
                            Label("Record User Breadcrumb", systemImage: "list.bullet")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button(action: performMockNetworkCall) {
                            Label("Trigger Mock Network Request", systemImage: "network")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button(action: { ARTracker.flush { refreshMetrics() } }) {
                            Label("Flush Queue Immediately", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal)

                    // Crash Testing Section
                    VStack(spacing: 8) {
                        Text("Crash Diagnostics (Run without Xcode Debugger)")
                            .font(.caption)
                            .foregroundColor(.red)

                        Button(role: .destructive, action: triggerFatalError) {
                            Text("Trigger Swift fatalError (SIGTRAP)")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive, action: triggerSigSegv) {
                            Text("Trigger SIGSEGV (Null Pointer Deref)")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                }
                .padding(.vertical)
            }
            .navigationTitle("Dashboard")
        }
        .artrackerScreen("DashboardScreen")
        .onAppear {
            refreshMetrics()
        }
    }

    private func refreshMetrics() {
        ARTracker.debugMetrics { summary in
            DispatchQueue.main.async {
                self.metricsText = summary.description
            }
        }
    }

    private func sendManualEvent() {
        ARTracker.breadcrumb("Tapped Send Custom Event", category: "ui")
        let item = Item(
            type: .event,
            name: "button.tap",
            attributes: [
                "button_id": .string("send_custom_event"),
                "screen": .string("DashboardScreen")
            ]
        )
        ARTracker.shared.enqueueItem(item)
        refreshMetrics()
    }

    private func recordBreadcrumb() {
        ARTracker.breadcrumb("User interacted with Dashboard controls", category: "ui")
        refreshMetrics()
    }

    private func performMockNetworkCall() {
        guard let url = URL(string: "https://httpbin.org/get") else { return }
        let task = URLSession.shared.dataTask(with: url) { _, _, _ in
            DispatchQueue.main.async {
                self.refreshMetrics()
            }
        }
        task.resume()
    }

    private func triggerFatalError() {
        fatalError("Test crash via Swift fatalError (SIGTRAP)")
    }

    private func triggerSigSegv() {
        let pointer: UnsafeMutablePointer<Int>? = nil
        pointer!.pointee = 42
    }
}

// MARK: - Screen 2: Checkout & Session Replay View
struct CheckoutDetailView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var customerName: String = "John Doe"
    @State private var cardNumber: String = "4111 2222 3333 4444"
    @State private var cvv: String = "123"
    @State private var quantity: Int = 2
    @State private var alertMessage: String?
    @State private var showAlert: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text("Screen 2: Checkout & Replay")
                        .font(.title2)
                        .bold()
                    Text("Demonstrates multi-screen navigation, view tree capture, and sensitive data masking for Session Replay.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

                // Order Summary Card
                VStack(alignment: .leading, spacing: 12) {
                    Text("Order Summary")
                        .font(.headline)
                    HStack {
                        Text("ARTracker Pro Observability Pack")
                        Spacer()
                        Text("$199.00")
                            .bold()
                    }
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1...10)
                        .onChange(of: quantity) { newVal in
                            ARTracker.breadcrumb("Changed order quantity to \(newVal)", category: "order")
                        }
                    Divider()
                    HStack {
                        Text("Estimated Total:")
                            .bold()
                        Spacer()
                        Text("$\(quantity * 199).00")
                            .bold()
                            .foregroundColor(.blue)
                    }
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)

                // Masked Sensitive Input Form
                VStack(alignment: .leading, spacing: 12) {
                    Text("Payment Details (Session Replay Masked)")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cardholder Name")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Name", text: $customerName)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Credit Card (Auto-Masked)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Card Number", text: $cardNumber)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .artrackerMask()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("CVV / Security Code (Secure & Masked)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SecureField("CVV", text: $cvv)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .artrackerMask()
                    }
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)

                // Screen 2 Actions
                VStack(spacing: 12) {
                    Button(action: simulatePaymentRequest) {
                        Label("Simulate Payment API Call", systemImage: "creditcard.and.123")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: simulateOrderError) {
                        Label("Simulate Non-Fatal Payment Error", systemImage: "exclamationmark.triangle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)

                    Button(action: completeOrder) {
                        Label("Complete Order & Return", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle("Checkout")
        .artrackerScreen("CheckoutScreen")
        .alert(isPresented: $showAlert) {
            Alert(
                title: Text("Notice"),
                message: Text(alertMessage ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func simulatePaymentRequest() {
        ARTracker.breadcrumb("Initiating mock payment transaction", category: "payment")
        guard let url = URL(string: "https://httpbin.org/post") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"amount\": \(quantity * 199)}".utf8)

        URLSession.shared.dataTask(with: request) { _, response, _ in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                alertMessage = "Payment API responded with status HTTP \(statusCode)"
                showAlert = true
            }
        }.resume()
    }

    private func simulateOrderError() {
        ARTracker.breadcrumb("Simulating payment authorization failure", category: "payment")
        struct PaymentError: LocalizedError {
            var errorDescription: String? { "Card issuer declined transaction (Insufficient Funds)" }
        }
        ARTracker.capture(
            error: PaymentError(),
            message: "Simulated order decline on CheckoutScreen",
            attributes: [
                "order_amount": quantity * 199,
                "customer_name": customerName
            ]
        )
        alertMessage = "Captured non-fatal error to ARTracker with stack trace and breadcrumbs."
        showAlert = true
    }

    private func completeOrder() {
        ARTracker.breadcrumb("Order successfully submitted", category: "order")
        let item = Item(
            type: .event,
            name: "checkout.completed",
            attributes: [
                "screen": .string("CheckoutScreen"),
                "total_amount": .number(Double(quantity * 199)),
                "item_count": .number(Double(quantity))
            ]
        )
        ARTracker.shared.enqueueItem(item)
        ARTracker.flush()
        presentationMode.wrappedValue.dismiss()
    }
}
