# ARTracker iOS SDK (`artracker-ios-sdk`)

[![iOS Target](https://img.shields.io/badge/iOS-15.0%2B-blue.svg)](https://developer.apple.com/ios/)
[![Swift Version](https://img.shields.io/badge/Swift-5.9%20%7C%206.0-orange.svg)](https://swift.org)
[![Xcode](https://img.shields.io/badge/Xcode-15.0%2B-blueviolet.svg)](https://developer.apple.com/xcode/)
[![Status](https://img.shields.io/badge/Tests-36%20Passed-brightgreen.svg)]()

SDK Observabilitas dan Crash Intelligence resmi untuk platform **ARTracker** pada aplikasi native iOS (SwiftUI & UIKit).

Dirancang khusus dengan prinsip **Ultra Low Overhead** dan **Privacy First**:
* **Instant Startup**: Inisialisasi 2-Fase non-blocking dengan budget main thread **<= 2.0 ms** (aktual benchmark: **~0.140 ms**).
* **Crash & Signal Handling**: Tangkapan crash berbasis `PLCrashReporter` (Mach exceptions & BSD signals) dengan mmap memory context preservation, replay saat peluncuran berikutnya, dan proteksi otomatis konflik LLDB debugger (`SIGTRAP` prevention).
* **Session Replay & View Hierarchy**: Pengambilan pohon tampilan (view tree) yang ringkas dan otomatis menyamarkan input sensitif (`SecureField`, password, kartu kredit).
* **Universal Network Capture**: Intersepsi otomatis `URLSession` untuk mencatat status HTTP, latensi, dan ukuran payload dengan sanitasi header sensitif (Authorization, Cookie).
* **Offline Reliability**: Antrean lokal berbasis SQLite WAL berkapasitas 2.000 item / 5 MB dengan kompresi data RFC 1952 Gzip dan jittered exponential backoff.
* **Apple Privacy Manifest**: Dilengkapi `PrivacyInfo.xcprivacy` tanpa IDFA atau tracking cross-app.

---

## 📋 Persyaratan

| Komponen | Spesifikasi Minimum |
|---|---|
| **Sistem Operasi** | iOS 15.0+ / macOS 12.0+ (Simulator & Device) |
| **Bahasa Pemrograman** | Swift 5.9+ / Swift 6.0 |
| **Toolchain** | Xcode 15.0+ |
| **Package Manager** | Swift Package Manager (SPM) |

---

## 📦 Instalasi

### Menggunakan Swift Package Manager (SPM)

Tambahkan dependensi paket ke dalam file `Package.swift` proyek Anda:

```swift
dependencies: [
    .package(url: "https://github.com/artracker/artracker-ios-sdk.git", from: "0.1.0")
]
```

Atau melalui Xcode:
1. Pilih **File** > **Add Package Dependencies...**
2. Masukkan repository URL: `https://github.com/artracker/artracker-ios-sdk.git`
3. Pilih dependency rule **Up to Next Major Version** (`0.1.0`).
4. Centang target aplikasi Anda untuk menyertakan library **ARTracker**.

---

## 🚀 Quick Start & Inisialisasi

Panggil `ARTracker.configure` seawal mungkin di siklus hidup aplikasi (**Fase A**: bootstrap ringan <= 2 ms di main thread; **Fase B**: database, network, dan crash engine berjalan di background).

### Integrasi SwiftUI

Tambahkan di konstruktor `init()` dari file `@main struct App`:

```swift
import SwiftUI
import ARTracker

@main
struct MyApp: App {
    init() {
        ARTracker.configure(
            endpoint: "https://artracker.exlm.my.id",
            appKey: "art_live_xxxxxxxxxxxxxxxxxxxxxxxxxxx",
            config: ARTrackerConfig(
                environment: "production",
                enableNetworkCapture: true,
                enableViewCapture: true,
                maskAllText: false,
                wifiOnly: false,      // default: false (mengizinkan seluler & Wi-Fi)
                flushInterval: 30,    // interval flush rutin dalam detik
                debugLogging: false
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

### Integrasi UIKit

Tambahkan di `application(_:didFinishLaunchingWithOptions:)` pada `AppDelegate.swift`:

```swift
import UIKit
import ARTracker

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        ARTracker.configure(
            endpoint: "https://artracker.exlm.my.id",
            appKey: "art_live_xxxxxxxxxxxxxxxxxxxxxxxxxxx",
            config: ARTrackerConfig(
                environment: "production",
                enableNetworkCapture: true,
                enableViewCapture: true
            )
        )
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        ARTracker.handleBackgroundEvents(completionHandler)
    }
}
```

---

## 🛠️ Konfigurasi SDK (`ARTrackerConfig`)

| Parameter | Tipe | Default | Deskripsi |
|---|---|---|---|
| `environment` | `String` | `"production"` | Lingkungan aplikasi (`"production"`, `"staging"`, `"development"`). |
| `enableNetworkCapture`| `Bool` | `true` | Merekam performa panggilan HTTP via `URLSession`. |
| `instrumentAllSessions` | `Bool` | `true` | Melakukan swizzling konfigurasi session default/ephemeral untuk network capture global. |
| `enableViewCapture` | `Bool` | `true` | Menangkap view tree hierarchy untuk analitik layar dan Session Replay. |
| `maskAllText` | `Bool` | `false` | Menyamarkan seluruh teks pada view tree (`*`). |
| `wifiOnly` | `Bool` | `false` | Hanya mengunggah data saat terhubung ke Wi-Fi. Default `false` mengizinkan jaringan seluler. |
| `flushInterval` | `TimeInterval`| `30.0` | Interval berkala (detik) pengiriman batch item dari disk queue ke backend. |
| `maxBatchItems` | `Int` | `50` | Maksimum item yang digabungkan dalam satu request upload (maks 100). |
| `debugLogging` | `Bool` | `false` | Menampilkan log internal SDK via OSLog di console debugger. |

---

## 💡 Panduan Fitur & Penggunaan

### 1. Pelacakan Layar & Session Replay Masking

SDK secara otomatis mendeteksi nama screen pada UIKit (`UIViewController.viewDidAppear`). Untuk SwiftUI, gunakan view modifier `.artrackerScreen()`:

```swift
// Menandai nama layar pada SwiftUI
HomeScreenView()
    .artrackerScreen("HomeScreen")

// Menyamarkan input sensitif agar tidak terekam pada Session Replay
SecureField("Password", text: $password)
    .artrackerMask()

TextField("Nomor Rekening", text: $accountNumber)
    .artrackerMask()
```

Pada UIKit, Anda dapat menyamarkan view kustom dengan identifier `mask:view`:
```swift
textField.accessibilityIdentifier = "mask:view"
```

### 2. Pencatatan Breadcrumbs & User Identity

```swift
// Identitas Pengguna
ARTracker.setUser(id: "user_usr_12345")

// Jejak navigasi / UI Breadcrumbs
ARTracker.breadcrumb("User menekan tombol checkout", category: "ui")
ARTracker.breadcrumb("Navigasi ke OrderDetailView", category: "navigation", type: "navigation")
```

### 3. Tangkapan Error Non-Fatal (`capture`)

Error manual yang ditangkap otomatis menyertakan `stack_trace` (`Thread.callStackSymbols`), riwayat breadcrumbs terakhir, dan detail lengkap perangkat (`device_info`):

```swift
do {
    try processPayment()
} catch {
    ARTracker.capture(
        error: error,
        message: "Gagal memproses transaksi pembayaran",
        attributes: [
            "cart_id": "cart_99812",
            "amount": 250000
        ]
    )
}
```

### 4. Custom Events & Flush Antrean

```swift
// Mengirimkan event bisnis kustom
let item = Item(
    type: .event,
    name: "checkout.completed",
    attributes: [
        "order_id": .string("ord_5521"),
        "total": .number(250000)
    ]
)
ARTracker.shared.enqueueItem(item)

// Memaksa pengiriman seluruh antrean sekarang juga
ARTracker.flush {
    print("Seluruh antrean telemetri berhasil terkirim.")
}
```

### 5. Debugger & Crash Handling Safety

SDK dilengkapi mekanisme keamanan **`DebuggerDetector`**:
* Saat aplikasi dijalankan langsung dari Xcode (`⌘R`), handler Mach dari `PLCrashReporter` otomatis di-bypass agar tidak memicu `SIGTRAP` (Signal 5) akibat bentrokan port exception dengan debugger LLDB.
* **Untuk menguji crash reporting nyata (SIGSEGV / SIGTRAP)**:
  1. Hentikan (Stop) debugging di Xcode.
  2. Buka aplikasi secara independen langsung dari homescreen Simulator atau Device.
  3. Picu crash, lalu luncurkan kembali aplikasi. SDK akan membaca crash report via mmap storage dan mengirimkannya ke backend saat startup Fase B.

---

## 🗂️ Aplikasi Sampel (Demo Apps)

Folder [`Samples/`](Samples/) menyediakan 2 implementasi demo aplikasi multi-screen (minimal 2 layar):

1. **`ARTrackerDemoSwiftUI`**:
   * **Screen 1 (`DashboardScreen`)**: Metrik SDK real-time, custom event, breadcrumbs, mock HTTP request, dan crash test triggers.
   * **Screen 2 (`CheckoutScreen`)**: Alur checkout dengan view tree capture, stepper order breadcrumb, form data sensitif bermasking (`.artrackerMask()`), mock payment API, dan non-fatal error capture.
2. **`ARTrackerDemoUIKit`**:
   * **Screen 1 (`HomeViewController`)**: Auto `viewDidAppear` swizzled screen tracking, tombol push ke Screen 2.
   * **Screen 2 (`ProfileViewController`)**: Form profil dengan input sensitif bermasking (`mask:view`), API call simulation, dan validation error trigger.

### Menjalankan Demo Apps:
```bash
# 1. Generate project Xcode menggunakan XcodeGen
cd Samples
xcodegen generate

# 2. Buka project di Xcode
open ARTrackerDemos.xcodeproj
```

---

## 📤 Upload dSYM Symbolication

Untuk melakukan de-simbolikasi crash stack trace di server, gunakan helper script [`Scripts/upload-dsym.sh`](Scripts/upload-dsym.sh):

```bash
# Upload manual via Terminal
./Scripts/upload-dsym.sh --api-key "YOUR_ARTRACKER_API_KEY" /path/to/App.app.dSYM

# Atau pasang pada Xcode Run Script Build Phase (khusus Release):
if [ "$CONFIGURATION" = "Release" ]; then
    "${PROJECT_DIR}/../Scripts/upload-dsym.sh" --api-key "$ARTRACKER_API_KEY"
fi
```

---

## 📊 Hasil Pengujian & Benchmark Empiris

Seluruh pengujian dan bukti benchmark tersimpan di folder [`docs/evidence/`](docs/evidence/):

* **Startup Phase A Benchmark**: [`docs/evidence/launch-metrics.txt`](docs/evidence/launch-metrics.txt)
  * **Median**: `0.140 ms` | **p95**: `0.180 ms` (Budget: `<= 2.0 ms` di main thread).
* **CPU Idle Overhead Profile**: [`docs/evidence/cpu-trace.txt`](docs/evidence/cpu-trace.txt)
  * **Overhead CPU**: `0.05%` (Budget: `< 0.5%` foreground idle).
* **Offline SQLite WAL & Gzip Ingestion**: [`docs/evidence/e2e-offline.md`](docs/evidence/e2e-offline.md)
  * Verifikasi penyimpanan offline antrean SQLite WAL (max 2.000 records) dan kompresi RFC 1952 Gzip (`0x1F, 0x8B`) saat backend menerima payload ingest (`HTTP 202 Accepted`).
* **Unit Test Suite**:
  * **36 unit tests passed** dalam `0.172 detik` (`swift test`).

---

## 📚 Dokumen Terkait

* [PLAN_V2.md](docs/PLAN_V2.md) - Rencana kerja teknis, gap remediation, dan kontrak backend.
* [PLAN_REPLAY_IOS.md](docs/PLAN_REPLAY_IOS.md) - Blueprint Session Replay via Native View Tree * [PLAN_V2.md](docs/PLAN_V2.md) - Rencana kerja teknis, gap remediation, dan kontrak backend. Wireframe Engine.
* [INTEGRATION.md](docs/INTEGRATION.md) - Panduan integrasi mendalam untuk tim developer.
* [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) - Panduan resolusi masalah dan FAQ.
