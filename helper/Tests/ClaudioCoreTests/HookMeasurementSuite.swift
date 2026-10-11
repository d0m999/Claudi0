import ClaudioCore
import Foundation

@MainActor
func runHookMeasurementSuites() {
    suite("hook measurement: disabled, scoped, throwing and bounded collection") {
        expect(HookMeasurementContext.current == nil, "measurement is off by default")
        var disabledCalls = 0
        let disabledValue = HookMeasurementContext.measure(.activity) {
            disabledCalls += 1
            return 7
        }
        expect(
            disabledValue == 7 && disabledCalls == 1 && HookMeasurementContext.current == nil,
            "disabled observer executes the operation once and preserves its value")
        let outer = HookMeasurementContext()
        let inner = HookMeasurementContext()
        enum Expected: Error { case failure }
        HookMeasurementContext.$current.withValue(outer) {
            do {
                try HookMeasurementContext.measure(.versionResolution) {
                    throw Expected.failure
                }
                expect(false, "observer must preserve thrown errors")
            } catch Expected.failure {} catch { expect(false, "same error reaches caller") }
            HookMeasurementContext.$current.withValue(inner) {
                HookMeasurementContext.record(.handling, .rejectedAuthorization)
            }
            let value = HookMeasurementContext.measure(.activity) { 42 }
            expect(value == 42, "observer preserves return values")
        }
        expect(HookMeasurementContext.current == nil, "scope restores disabled context")
        expect(
            outer.snapshot.count == 2 && outer.snapshot.allSatisfy { $0.nanoseconds != nil },
            "inclusive spans survive early throws without leaking nested events")
        expect(
            inner.snapshot.map(\.result) == [.rejectedAuthorization],
            "results belong to one invocation")
        HookMeasurementContext.$current.withValue(inner) {
            for _ in 0..<1100 { HookMeasurementContext.record(.handling, .accepted) }
        }
        expect(
            inner.snapshot.count == 1024 && inner.droppedRecordCount == 77,
            "bounded observer exposes overflow instead of silently reporting complete evidence")
    }
}
