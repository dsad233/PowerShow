import Foundation
import IOKit
import CoreFoundation
import AppKit

class PowerMonitor {
    private var timer: Timer?
    private let updateHandler: (Double?) -> Void
    
    private var powerHistory: [Double] = []
    private let maxHistoryCount = 10 // 진짜 센서값이므로 반응속도를 위해 평균 구간을 줄임

    init(updateHandler: @escaping (Double?) -> Void) {
        self.updateHandler = updateHandler
    }
    
    func start() {
        // 1초 주기로 하드웨어 센서 직접 갱신
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.fetchRealHardwarePower()
        }
        fetchRealHardwarePower()
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
        powerHistory.removeAll()
    }
    
    private func fetchRealHardwarePower() {
        DispatchQueue.global(qos: .userInitiated).async {
            // ⭐️ [SMC/IOPMPowerSource 다이렉트 센서 덤프]
            let realPower = self.getRealSystemPower()
            
            // 값을 정상적으로 읽어왔다면 히스토리에 추가
            if realPower > 0.0 {
                self.powerHistory.append(realPower)
                if self.powerHistory.count > self.maxHistoryCount {
                    self.powerHistory.removeFirst()
                }
                
                let totalSum = self.powerHistory.reduce(0.0, +)
                let averageTotalPower = totalSum / Double(self.powerHistory.count)
                
                self.updateHandler(averageTotalPower)
            } else {
                // 센서 권한이 완전히 막혔을 경우 기존 백업 가상 엔진으로 돌아감
                self.updateHandler(self.getBackupEstimatedPower())
            }
        }
    }
    
    // ⭐️ [진짜 하드웨어 배터리/파워 센서 읽기]
    private func getRealSystemPower() -> Double {
        // AppleSmartBattery (맥북) 또는 AppleSMC (맥미니) 레지스트리 탐색
        let matchingDict = IOServiceMatching("IOPMPowerSource")
        var iterator: io_iterator_t = 0
        
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)
        guard result == KERN_SUCCESS else { return 0.0 }
        
        var totalPower: Double = 0.0
        var service = IOIteratorNext(iterator)
        
        while service != 0 {
            var serviceProperties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &serviceProperties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let properties = serviceProperties?.takeRetainedValue() as? [String: Any] {
                
                // 전압(Voltage)과 전류(Amperage)를 읽어와서 W(와트)를 계산합니다. (W = V * A)
                let voltage = properties["Voltage"] as? Double ?? properties["AppleRawMaxCapacity"] as? Double ?? 0.0
                let amperage = properties["Amperage"] as? Double ?? properties["InstantAmperage"] as? Double ?? 0.0
                
                // 전류가 음수(방전)이든 양수(충전)이든 절대값으로 전력 소모량을 구합니다.
                // 보통 mV, mA 단위로 나오므로 W로 변환하기 위해 1,000,000으로 나눕니다.
                if voltage > 0 && amperage != 0 {
                    let watts = (voltage * abs(amperage)) / 1_000_000.0
                    totalPower += watts
                }
            }
            
            let nextService = IOIteratorNext(iterator)
            IOObjectRelease(service)
            service = nextService
        }
        
        IOObjectRelease(iterator)
        return totalPower
    }

    // 센서 접근 실패 시 돌아가는 백업 계산 엔진 (이전 버전보다 반응성 강화)
    private func getBackupEstimatedPower() -> Double {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        var loadInfo = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &loadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 2.0 }
        
        let user = Double(loadInfo.cpu_ticks.0)
        let system = Double(loadInfo.cpu_ticks.1)
        let idle = Double(loadInfo.cpu_ticks.2)
        
        // 이전 상태를 저장하는 static 변수 꼼수 (간결화를 위해)
        struct StaticVars {
            static var prevUser = 0.0
            static var prevSystem = 0.0
            static var prevIdle = 0.0
        }
        
        let deltaUser = user - StaticVars.prevUser
        let deltaSystem = system - StaticVars.prevSystem
        let deltaIdle = idle - StaticVars.prevIdle
        let totalDelta = deltaUser + deltaSystem + deltaIdle
        
        StaticVars.prevUser = user
        StaticVars.prevSystem = system
        StaticVars.prevIdle = idle
        
        let cpuLoad = totalDelta > 0 ? (deltaUser + deltaSystem) / totalDelta : 0.0
        
        // 백업 엔진일지라도 M4 특성에 맞춰 27W까지 치솟도록 커브를 수정
        let peakPower = 27.0
        let basePower = 1.5
        // cpuLoad가 높아질 때 수치가 확 튀어오르도록 pow 조정
        let backupPower = basePower + (pow(cpuLoad, 1.2) * peakPower)
        
        return backupPower
    }
}
