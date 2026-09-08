import Foundation
import IOKit
import CoreFoundation
import AppKit

class PowerMonitor {
    private var timer: Timer?
    private let updateHandler: (Double?) -> Void
    
    private var prevCpuTicks: (user: Double, system: Double, idle: Double)?
    private var powerHistory: [Double] = []
    private let maxHistoryCount = 30 // 반응성을 높이기 위해 평균 기간을 살짝 줄임

    // [Apple Silicon 실제 유휴 상태에 맞춘 현실적인 수치로 하향 조정]
    private let baseIdlePower: Double = 1.5    // 아무것도 안 할 때의 칩셋 기본 전력 (약 1.5W)
    private let peakCpuPower: Double = 22.0    // CPU 100% 풀로드 시 추가 전력
    private let peakGpuPower: Double = 12.0
    private let peakAmxPower: Double = 10.0

    init(updateHandler: @escaping (Double?) -> Void) {
        self.updateHandler = updateHandler
    }
    
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.fetchTotalPowerUsage()
        }
        fetchTotalPowerUsage()
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
        powerHistory.removeAll()
    }
    
    private func fetchTotalPowerUsage() {
        DispatchQueue.global(qos: .background).async {
            let cpuLoad = self.getRealtimeCpuLoad()
            let gpuLoad = self.getRealtimeGpuLoad()
            
            // 1. [핵심 변경] CPU 로드 비선형 곡선 수정 (가벼운 작업 시 전력 소모 극소화)
            // pow(cpuLoad, 1.4)를 적용하면 10% 가동 시 0.8W, 50% 가동 시 8W, 100% 시 22W로 상승합니다.
            let adjustedCpuPower = pow(cpuLoad, 1.4) * self.peakCpuPower
            
            // 2. AMX (행렬 연산기) 추정 전력 (매우 무거운 작업일 때만 개입)
            var amxEstimatedPower = 0.0
            if cpuLoad > 0.3 && gpuLoad > 0.2 {
                let synergyLoad = min(cpuLoad * 1.5, 1.0) * min(gpuLoad * 1.5, 1.0)
                amxEstimatedPower = synergyLoad * self.peakAmxPower
            }
            
            // 3. 총 전력 계산
            let currentInstantPower = self.baseIdlePower + adjustedCpuPower + (gpuLoad * self.peakGpuPower) + amxEstimatedPower
            
            self.powerHistory.append(currentInstantPower)
            if self.powerHistory.count > self.maxHistoryCount {
                self.powerHistory.removeFirst()
            }
            
            let totalSum = self.powerHistory.reduce(0.0, +)
            let averageTotalPower = totalSum / Double(self.powerHistory.count)
            
            // 최종 값을 화면에 전달
            self.updateHandler(averageTotalPower)
        }
    }
    
    private func getRealtimeCpuLoad() -> Double {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        var loadInfo = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &loadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0.0 }
        
        let currentUser = Double(loadInfo.cpu_ticks.0)
        let currentSystem = Double(loadInfo.cpu_ticks.1)
        let currentIdle = Double(loadInfo.cpu_ticks.2)
        
        guard let prev = prevCpuTicks else {
            prevCpuTicks = (currentUser, currentSystem, currentIdle)
            return 0.0
        }
        
        let userDelta = currentUser - prev.user
        let systemDelta = currentSystem - prev.system
        let idleDelta = currentIdle - prev.idle
        let totalDelta = userDelta + systemDelta + idleDelta
        
        prevCpuTicks = (currentUser, currentSystem, currentIdle)
        
        return totalDelta > 0 ? (userDelta + systemDelta) / totalDelta : 0.0
    }
    
    private func getRealtimeGpuLoad() -> Double {
        var matchingDict = IOServiceMatching("AGXAccelerator") as? [String: Any]
        if matchingDict == nil {
            matchingDict = IOServiceMatching("IOAccelerator") as? [String: Any]
        }
        
        guard let searchDict = matchingDict else { return getSoftwareEstimatedGpuLoad() }
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(0, searchDict as CFDictionary, &iterator)
        
        if result == KERN_SUCCESS {
            var service = IOIteratorNext(iterator)
            while service != 0 {
                var serviceProperties: Unmanaged<CFMutableDictionary>?
                
                if IORegistryEntryCreateCFProperties(service, &serviceProperties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let properties = serviceProperties?.takeRetainedValue() as? [String: Any] {
                    
                    if let stats = properties["PerformanceStatistics"] as? [String: Any] {
                        let gpuBusy = stats["gpu_busy_percentage"] as? Double
                            ?? stats["Device Utilization"] as? Double
                            ?? stats["GPU Activity"] as? Double
                            ?? 0.0
                        
                        if gpuBusy > 0 {
                            IOObjectRelease(service)
                            IOObjectRelease(iterator)
                            return gpuBusy > 1.0 ? gpuBusy / 100.0 : gpuBusy
                        }
                    }
                }
                
                let nextService = IOIteratorNext(iterator)
                IOObjectRelease(service)
                service = nextService
            }
            IOObjectRelease(iterator)
        }
        return getSoftwareEstimatedGpuLoad()
    }

    private func getSoftwareEstimatedGpuLoad() -> Double {
        let currentCpu = getRealtimeCpuLoad()
        let mainDisplay = CGMainDisplayID()
        
        if CGDisplayIsActive(mainDisplay) != 0 {
            let isMouseMoving = NSEvent.mouseLocation != .zero
            // GPU 가상 부하도 크게 낮췄습니다 (가벼운 마우스 움직임은 거의 전력을 먹지 않음)
            var estimatedLoad = currentCpu * 0.4
            
            if isMouseMoving { estimatedLoad += 0.01 }
            return min(estimatedLoad, 0.8)
        }
        return 0.0
    }
}
