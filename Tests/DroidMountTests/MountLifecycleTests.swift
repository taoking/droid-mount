import Testing
@testable import DroidMount

/// A lifecycle with a phone attached and its volume mounted.
private func mountedLifecycle() -> MountLifecycle {
    var lifecycle = MountLifecycle()
    _ = lifecycle.handle(.deviceConnectionChanged(true))
    _ = lifecycle.handle(.volumeAppeared)
    return lifecycle
}

@Test
func connectingAPhoneStartsAMount() {
    var lifecycle = MountLifecycle()
    #expect(lifecycle.handle(.deviceConnectionChanged(true)) == [.cancelRetry, .startHelper])
    #expect(lifecycle.phase == .mounting)

    #expect(lifecycle.handle(.volumeAppeared) == [])
    #expect(lifecycle.phase == .mounted)
    #expect(lifecycle.statusText == "Android 已挂载到 Finder")
}

@Test
func repeatedConnectionReportsChangeNothing() {
    var lifecycle = mountedLifecycle()
    #expect(lifecycle.handle(.deviceConnectionChanged(true)) == [])
    #expect(lifecycle.phase == .mounted)

    var idle = MountLifecycle()
    #expect(idle.handle(.deviceConnectionChanged(false)) == [])
    #expect(idle.statusText == "等待 Android MTP 设备")
}

@Test
func ejectFromTheMenuPausesAutoMountUntilThePhoneIsUnplugged() {
    var lifecycle = mountedLifecycle()
    #expect(lifecycle.handle(.unmountRequested) == [.unmountVolume])
    #expect(lifecycle.phase == .unmounting)

    #expect(lifecycle.handle(.helperExited(.unmounted)) == [])
    #expect(lifecycle.phase == .idle)
    #expect(lifecycle.pausedByUser)
    #expect(lifecycle.statusText.hasPrefix("Android 已推出"))
    // A retry or a stray USB event must not mount the volume right back.
    #expect(lifecycle.handle(.retryTimerFired) == [])
    #expect(lifecycle.handle(.deviceConnectionChanged(true)) == [])

    // Unplugging ends the pause; plugging the phone back in mounts it again.
    #expect(lifecycle.handle(.deviceConnectionChanged(false)) == [.cancelRetry])
    #expect(!lifecycle.pausedByUser)
    #expect(lifecycle.handle(.deviceConnectionChanged(true)) == [.cancelRetry, .startHelper])
}

@Test
func ejectFromFinderIsRespected() {
    var lifecycle = mountedLifecycle()
    // Finder's eject unmounts the volume underneath the helper, which then exits 0.
    #expect(lifecycle.handle(.helperExited(.unmounted)) == [])
    #expect(lifecycle.phase == .idle)
    #expect(lifecycle.pausedByUser)
    #expect(lifecycle.failure == nil)
}

@Test
func cleanExitAfterUnplugDoesNotPause() {
    var lifecycle = mountedLifecycle()
    #expect(lifecycle.handle(.deviceConnectionChanged(false)) == [.cancelRetry, .stopHelper])
    #expect(lifecycle.handle(.helperExited(.unmounted)) == [])
    #expect(!lifecycle.pausedByUser)
    #expect(lifecycle.statusText == "等待 Android MTP 设备")
}

@Test
func mountRequestOverridesThePause() {
    var lifecycle = mountedLifecycle()
    _ = lifecycle.handle(.unmountRequested)
    _ = lifecycle.handle(.helperExited(.unmounted))
    #expect(lifecycle.pausedByUser)

    #expect(lifecycle.handle(.mountRequested) == [.cancelRetry, .startHelper])
    #expect(!lifecycle.pausedByUser)
    #expect(lifecycle.phase == .mounting)
}

@Test
func unplugWhileMountedStopsTheHelper() {
    var lifecycle = mountedLifecycle()
    #expect(lifecycle.handle(.deviceConnectionChanged(false)) == [.cancelRetry, .stopHelper])
    #expect(lifecycle.phase == .unmounting)
    // However the helper dies once its phone is gone, it is not a failure to report.
    #expect(lifecycle.handle(.helperExited(.failed("libc++abi: terminating"))) == [])
    #expect(lifecycle.phase == .idle)
    #expect(lifecycle.failure == nil)
}

@Test
func replugDuringTeardownMountsOnceTheOldHelperIsGone() {
    var lifecycle = mountedLifecycle()
    _ = lifecycle.handle(.deviceConnectionChanged(false))
    #expect(lifecycle.handle(.deviceConnectionChanged(true)) == [])
    #expect(lifecycle.phase == .unmounting)
    #expect(lifecycle.handle(.helperExited(.failed(""))) == [.cancelRetry, .startHelper])
    #expect(lifecycle.phase == .mounting)
}

@Test
func helperCrashWhileMountedRetries() {
    var lifecycle = mountedLifecycle()
    #expect(lifecycle.handle(.helperExited(.failed("Segmentation fault"))) == [.scheduleRetry(seconds: 2)])
    #expect(lifecycle.phase == .idle)
    #expect(lifecycle.failure == .helperFailed("Segmentation fault"))
    #expect(lifecycle.handle(.retryTimerFired) == [.cancelRetry, .startHelper])
}

@Test
func failedAttemptsBackOff() {
    var lifecycle = MountLifecycle()
    _ = lifecycle.handle(.deviceConnectionChanged(true))
    var delays: [Int] = []
    for _ in 0..<6 {
        for command in lifecycle.handle(.helperExited(.failed("fuse: mount failed"))) {
            if case .scheduleRetry(let seconds) = command {
                delays.append(seconds)
            }
        }
        _ = lifecycle.handle(.retryTimerFired)
    }
    #expect(delays == [2, 4, 8, 15, 15, 15])

    // Success resets the backoff.
    _ = lifecycle.handle(.volumeAppeared)
    #expect(lifecycle.consecutiveFailures == 0)
}

@Test
func connectedPhoneTheHelperCannotOpenIsBusy() {
    var lifecycle = MountLifecycle()
    _ = lifecycle.handle(.deviceConnectionChanged(true))
    let commands = lifecycle.handle(.helperExited(.failed("connect failed: no MTP device found\n")))
    #expect(commands == [.scheduleRetry(seconds: 2)])
    #expect(lifecycle.failure == .deviceBusy)
    #expect(lifecycle.statusText.hasPrefix("手机已连接，但 MTP 接口被其他程序占用"))
}

@Test
func manualMountWithoutAPhoneIsNotRetried() {
    var lifecycle = MountLifecycle()
    #expect(lifecycle.handle(.mountRequested) == [.cancelRetry, .startHelper])
    #expect(lifecycle.handle(.helperExited(.failed("connect failed: no MTP device found"))) == [])
    #expect(lifecycle.failure == .noDevice)
}

@Test
func timeoutIsReportedAsSuch() {
    var lifecycle = MountLifecycle()
    _ = lifecycle.handle(.deviceConnectionChanged(true))
    #expect(lifecycle.handle(.helperExited(.timedOut)) == [.scheduleRetry(seconds: 2)])
    #expect(lifecycle.failure == .timedOut)
}

@Test
func refusedEjectKeepsTheVolumeMounted() {
    var lifecycle = mountedLifecycle()
    _ = lifecycle.handle(.unmountRequested)
    #expect(lifecycle.handle(.unmountRefused) == [])
    #expect(lifecycle.phase == .mounted)
    #expect(!lifecycle.pausedByUser)
    #expect(lifecycle.statusText.hasPrefix("Android 卷正在使用中"))

    // A later successful eject clears the notice.
    _ = lifecycle.handle(.unmountRequested)
    #expect(lifecycle.failure == nil)
}

@Test
func ejectWhileMountingStopsTheHelper() {
    var lifecycle = MountLifecycle()
    _ = lifecycle.handle(.deviceConnectionChanged(true))
    #expect(lifecycle.handle(.unmountRequested) == [.stopHelper])
    #expect(lifecycle.handle(.volumeAppeared) == [])
    #expect(lifecycle.phase == .unmounting)
    #expect(lifecycle.handle(.helperExited(.failed(""))) == [])
    #expect(lifecycle.pausedByUser)
}

@Test
func staleEventsAreIgnored() {
    var lifecycle = MountLifecycle()
    #expect(lifecycle.handle(.volumeAppeared) == [])
    #expect(lifecycle.handle(.helperExited(.failed("old helper"))) == [])
    #expect(lifecycle.handle(.unmountRefused) == [])
    #expect(lifecycle.handle(.unmountRequested) == [])
    #expect(lifecycle.handle(.retryTimerFired) == [])
    #expect(lifecycle == MountLifecycle())

    var mounted = mountedLifecycle()
    #expect(mounted.handle(.retryTimerFired) == [])
    #expect(mounted.handle(.mountRequested) == [])
    #expect(mounted.phase == .mounted)
}

@Test
func failureMessagesQuoteTheLastLineOfOutput() {
    let output = "warning: something minor\nmount_macfuse: the file system is not available (1)\n\n"
    let failure = MountFailure(exit: .failed(output), deviceConnected: true)
    #expect(failure == .helperFailed("mount_macfuse: the file system is not available (1)"))
    #expect(failure.message == "挂载失败\nmount_macfuse: the file system is not available (1)")
    #expect(MountFailure(exit: .failed(""), deviceConnected: true).message == "挂载助手意外退出")

    let long = String(repeating: "x", count: 400)
    if case .helperFailed(let detail) = MountFailure(exit: .failed(long), deviceConnected: true) {
        #expect(detail.count == 161)
        #expect(detail.hasSuffix("…"))
    } else {
        Issue.record("expected a helper failure")
    }
}

@Test
func retryDelaysAreCapped() {
    #expect(MountLifecycle.retryDelay(afterFailures: 0) == 2)
    #expect(MountLifecycle.retryDelay(afterFailures: 1) == 2)
    #expect(MountLifecycle.retryDelay(afterFailures: 3) == 8)
    #expect(MountLifecycle.retryDelay(afterFailures: 4) == 15)
    #expect(MountLifecycle.retryDelay(afterFailures: 50) == 15)
}
