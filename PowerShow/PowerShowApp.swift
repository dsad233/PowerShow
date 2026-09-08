import SwiftUI
import ServiceManagement

@main
struct PowerShow: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false

    var body: some Scene {
        Window("PowerShow 설정", id: "settings") {
            VStack(spacing: 18) {
                Text("⚡️ PowerShow")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("실시간 시스템 총 전력 모니터링")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Divider()
                
                Toggle("맥북 켤 때 자동으로 실행하기", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { newValue in
                        updateLaunchAtLoginSetting(newValue)
                    }
                
                Divider()
                
                Text("이 창을 닫아도 상단 메뉴 바에서 계속 작동합니다.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding()
            .frame(width: 320, height: 200)
            .onAppear {
                updateLaunchAtLoginSetting(launchAtLogin)
            }
        }
        .windowStyle(.hiddenTitleBar)
    }
    
    private func updateLaunchAtLoginSetting(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            if enable {
                if service.status != .enabled {
                    try? service.register()
                }
            } else {
                if service.status == .enabled {
                    try? service.unregister()
                }
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    private var powerMonitor: PowerMonitor!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.title = "⚡️ -- W"
        }
        
        setupMenus()
        
        // 심플하게 총 전력(Total)만 받아와서 소수점 첫째 자리까지만 표시합니다.
        powerMonitor = PowerMonitor { [weak self] totalPower in
            DispatchQueue.main.async {
                if let powerValue = totalPower {
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                    ]
                    
                    // 메뉴 바에 출력될 심플한 포맷: "⚡️ 8.5 W"
                    let displayString = String(format: "⚡️ %.1f W", powerValue)
                    
                    self?.statusItem.button?.attributedTitle = NSAttributedString(
                        string: displayString,
                        attributes: attributes
                    )
                } else {
                    self?.statusItem.button?.title = "⚡️ -- W"
                }
            }
        }
        
        powerMonitor.start()
    }
    
    private func setupMenus() {
        let menu = NSMenu()
        
        let showSettingsItem = NSMenuItem(title: "설정 창 열기", action: #selector(showSettingsWindow), keyEquivalent: "s")
        menu.addItem(showSettingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "종료 (Quit)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    @objc private func showSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "") {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
