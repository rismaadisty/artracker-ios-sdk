import UIKit
import ARTracker

// MARK: - Screen 1: Home Dashboard View Controller
class HomeViewController: UIViewController {
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let metricsLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Home (Screen 1)"

        setupLayout()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshMetrics()
    }

    private func setupLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        ])

        // Title info
        let titleLabel = UILabel()
        titleLabel.text = "ARTracker UIKit Telemetry"
        titleLabel.font = .boldSystemFont(ofSize: 22)
        stack.addArrangedSubview(titleLabel)

        let subtitleLabel = UILabel()
        subtitleLabel.text = "Screen 1: Demonstrates automatic UIViewController viewDidAppear tracking and metrics."
        subtitleLabel.font = .systemFont(ofSize: 14)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0
        stack.addArrangedSubview(subtitleLabel)

        // Navigation Button to Screen 2
        let navButton = UIButton(type: .system)
        navButton.setTitle("Open Screen 2 (Profile & Replay) ➡️", for: .normal)
        navButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        navButton.backgroundColor = .systemBlue
        navButton.setTitleColor(.white, for: .normal)
        navButton.layer.cornerRadius = 10
        navButton.heightAnchor.constraint(equalToConstant: 48).isActive = true
        navButton.addTarget(self, action: #selector(didTapOpenScreen2), for: .touchUpInside)
        stack.addArrangedSubview(navButton)

        // Metrics card
        let metricsContainer = UIView()
        metricsContainer.backgroundColor = .secondarySystemBackground
        metricsContainer.layer.cornerRadius = 10
        metricsContainer.translatesAutoresizingMaskIntoConstraints = false

        let metricsHeader = UILabel()
        metricsHeader.text = "Live SDK Metrics"
        metricsHeader.font = .boldSystemFont(ofSize: 14)
        metricsHeader.translatesAutoresizingMaskIntoConstraints = false
        metricsContainer.addSubview(metricsHeader)

        metricsLabel.numberOfLines = 0
        metricsLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        metricsLabel.text = "Loading metrics..."
        metricsLabel.translatesAutoresizingMaskIntoConstraints = false
        metricsContainer.addSubview(metricsLabel)

        let refreshButton = UIButton(type: .system)
        refreshButton.setTitle("Refresh", for: .normal)
        refreshButton.titleLabel?.font = .systemFont(ofSize: 12)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.addTarget(self, action: #selector(didTapRefresh), for: .touchUpInside)
        metricsContainer.addSubview(refreshButton)

        NSLayoutConstraint.activate([
            metricsHeader.topAnchor.constraint(equalTo: metricsContainer.topAnchor, constant: 12),
            metricsHeader.leadingAnchor.constraint(equalTo: metricsContainer.leadingAnchor, constant: 12),

            refreshButton.centerYAnchor.constraint(equalTo: metricsHeader.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: metricsContainer.trailingAnchor, constant: -12),

            metricsLabel.topAnchor.constraint(equalTo: metricsHeader.bottomAnchor, constant: 8),
            metricsLabel.leadingAnchor.constraint(equalTo: metricsContainer.leadingAnchor, constant: 12),
            metricsLabel.trailingAnchor.constraint(equalTo: metricsContainer.trailingAnchor, constant: -12),
            metricsLabel.bottomAnchor.constraint(equalTo: metricsContainer.bottomAnchor, constant: -12)
        ])
        stack.addArrangedSubview(metricsContainer)

        // Action Buttons
        let eventButton = UIButton(type: .system)
        eventButton.setTitle("Send Manual Event", for: .normal)
        eventButton.backgroundColor = .systemGray6
        eventButton.layer.cornerRadius = 8
        eventButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        eventButton.addTarget(self, action: #selector(didTapSendEvent), for: .touchUpInside)
        stack.addArrangedSubview(eventButton)

        let breadcrumbButton = UIButton(type: .system)
        breadcrumbButton.setTitle("Add UI Breadcrumb", for: .normal)
        breadcrumbButton.backgroundColor = .systemGray6
        breadcrumbButton.layer.cornerRadius = 8
        breadcrumbButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        breadcrumbButton.addTarget(self, action: #selector(didTapBreadcrumb), for: .touchUpInside)
        stack.addArrangedSubview(breadcrumbButton)

        let httpButton = UIButton(type: .system)
        httpButton.setTitle("Trigger Mock HTTP Request", for: .normal)
        httpButton.backgroundColor = .systemGray6
        httpButton.layer.cornerRadius = 8
        httpButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        httpButton.addTarget(self, action: #selector(didTapHttpRequest), for: .touchUpInside)
        stack.addArrangedSubview(httpButton)

        let flushButton = UIButton(type: .system)
        flushButton.setTitle("Flush Queue Now", for: .normal)
        flushButton.backgroundColor = .systemGray6
        flushButton.layer.cornerRadius = 8
        flushButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        flushButton.addTarget(self, action: #selector(didTapFlush), for: .touchUpInside)
        stack.addArrangedSubview(flushButton)

        // Crash button
        let crashButton = UIButton(type: .system)
        crashButton.setTitle("Trigger Crash (SIGSEGV)", for: .normal)
        crashButton.setTitleColor(.systemRed, for: .normal)
        crashButton.backgroundColor = UIColor.systemRed.withAlphaComponent(0.1)
        crashButton.layer.cornerRadius = 8
        crashButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        crashButton.addTarget(self, action: #selector(didTapCrash), for: .touchUpInside)
        stack.addArrangedSubview(crashButton)
    }

    private func refreshMetrics() {
        ARTracker.debugMetrics { [weak self] summary in
            DispatchQueue.main.async {
                self?.metricsLabel.text = summary.description
            }
        }
    }

    @objc private func didTapOpenScreen2() {
        ARTracker.breadcrumb("User navigated to ProfileViewController", category: "navigation", type: "navigation")
        let profileVC = ProfileViewController()
        navigationController?.pushViewController(profileVC, animated: true)
    }

    @objc private func didTapRefresh() {
        refreshMetrics()
    }

    @objc private func didTapSendEvent() {
        ARTracker.breadcrumb("UIKit button tapped", category: "ui")
        let item = Item(
            type: .event,
            name: "button.tap",
            attributes: [
                "button_id": .string("uikit_manual_button"),
                "screen": .string("HomeViewController")
            ]
        )
        ARTracker.shared.enqueueItem(item)
        refreshMetrics()
    }

    @objc private func didTapBreadcrumb() {
        ARTracker.breadcrumb("User performed action on HomeViewController", category: "ui")
        refreshMetrics()
    }

    @objc private func didTapHttpRequest() {
        guard let url = URL(string: "https://httpbin.org/get") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                self?.refreshMetrics()
            }
        }.resume()
    }

    @objc private func didTapFlush() {
        ARTracker.flush { [weak self] in
            self?.refreshMetrics()
        }
    }

    @objc private func didTapCrash() {
        let ptr: UnsafeMutablePointer<Int>? = nil
        ptr!.pointee = 100
    }
}

// MARK: - Screen 2: Profile & Session Replay Masking View Controller
class ProfileViewController: UIViewController {
    private let nameField = UITextField()
    private let phoneField = UITextField()
    private let pinField = UITextField()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Profile & Security (Screen 2)"

        setupUI()
    }

    private func setupUI() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])

        let headerLabel = UILabel()
        headerLabel.text = "Session Replay & Masking Demo"
        headerLabel.font = .boldSystemFont(ofSize: 18)
        stack.addArrangedSubview(headerLabel)

        let descLabel = UILabel()
        descLabel.text = "View tree capture automatically masks sensitive fields below to preserve user privacy during session replay."
        descLabel.font = .systemFont(ofSize: 13)
        descLabel.textColor = .secondaryLabel
        descLabel.numberOfLines = 0
        stack.addArrangedSubview(descLabel)

        // Name
        nameField.placeholder = "Full Name"
        nameField.text = "Jane Doe"
        nameField.borderStyle = .roundedRect
        stack.addArrangedSubview(nameField)

        // Phone (Masked)
        phoneField.placeholder = "Phone Number (Masked)"
        phoneField.text = "+62 812-3456-7890"
        phoneField.borderStyle = .roundedRect
        phoneField.accessibilityIdentifier = "mask:view" // Custom masking marker
        stack.addArrangedSubview(phoneField)

        // PIN (Secure & Masked)
        pinField.placeholder = "Secret PIN (Masked)"
        pinField.isSecureTextEntry = true
        pinField.text = "987654"
        pinField.borderStyle = .roundedRect
        stack.addArrangedSubview(pinField)

        // Action Buttons
        let updateButton = UIButton(type: .system)
        updateButton.setTitle("Update Profile (Trigger Event)", for: .normal)
        updateButton.backgroundColor = .systemBlue
        updateButton.setTitleColor(.white, for: .normal)
        updateButton.layer.cornerRadius = 8
        updateButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        updateButton.addTarget(self, action: #selector(didTapUpdateProfile), for: .touchUpInside)
        stack.addArrangedSubview(updateButton)

        let apiButton = UIButton(type: .system)
        apiButton.setTitle("Simulate Profile API Update (HTTP)", for: .normal)
        apiButton.backgroundColor = .systemGray6
        apiButton.layer.cornerRadius = 8
        apiButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        apiButton.addTarget(self, action: #selector(didTapApiCall), for: .touchUpInside)
        stack.addArrangedSubview(apiButton)

        let errorButton = UIButton(type: .system)
        errorButton.setTitle("Simulate Profile Validation Error", for: .normal)
        errorButton.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.1)
        errorButton.setTitleColor(.systemOrange, for: .normal)
        errorButton.layer.cornerRadius = 8
        errorButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        errorButton.addTarget(self, action: #selector(didTapSimulateError), for: .touchUpInside)
        stack.addArrangedSubview(errorButton)

        let backButton = UIButton(type: .system)
        backButton.setTitle("Return to Screen 1", for: .normal)
        backButton.addTarget(self, action: #selector(didTapBack), for: .touchUpInside)
        stack.addArrangedSubview(backButton)
    }

    @objc private func didTapUpdateProfile() {
        ARTracker.breadcrumb("User updated profile settings", category: "profile")
        let item = Item(
            type: .event,
            name: "profile.updated",
            attributes: [
                "screen": .string("ProfileViewController"),
                "username": .string(nameField.text ?? "")
            ]
        )
        ARTracker.shared.enqueueItem(item)
        ARTracker.flush()

        let alert = UIAlertController(title: "Success", message: "Profile update event sent to ARTracker.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func didTapApiCall() {
        ARTracker.breadcrumb("Simulating profile sync API", category: "network")
        guard let url = URL(string: "https://httpbin.org/post") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{\"profile_id\": \"usr_123\"}".utf8)

        URLSession.shared.dataTask(with: req) { [weak self] _, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                let alert = UIAlertController(title: "Network Result", message: "API finished with HTTP \(code)", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(alert, animated: true)
            }
        }.resume()
    }

    @objc private func didTapSimulateError() {
        struct ProfileError: LocalizedError {
            var errorDescription: String? { "Profile verification failed: Phone number not verified." }
        }
        ARTracker.capture(
            error: ProfileError(),
            message: "Validation failed on ProfileViewController",
            attributes: ["field": "phone_number"]
        )
        let alert = UIAlertController(title: "Error Captured", message: "Non-fatal error logged to ARTracker with stack trace and breadcrumbs.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func didTapBack() {
        navigationController?.popViewController(animated: true)
    }
}
