import XCTest
import LidKeepCore
@testable import LidKeepApp

final class ThermalAlertControllerTests: XCTestCase {
    private final class FakePoster: AlertPosting {
        var permission = AlertPermission.allowed
        var grantOnRequest = false
        var authorizationRequests = 0
        var failures: [String] = []
        var deferCompletions = false
        var posts: [(title: String, body: String)] = []
        var waiting: [(String?) -> Void] = []
        func requestAuthorization(_ completion: @escaping (AlertPermission) -> Void) {
            authorizationRequests += 1
            if grantOnRequest { permission = .allowed }
            completion(permission)
        }
        func currentPermission(_ completion: @escaping (AlertPermission) -> Void) { completion(permission) }
        func post(title: String, body: String, completion: @escaping (String?) -> Void) {
            posts.append((title, body))
            let result = failures.isEmpty ? nil : failures.removeFirst()
            if deferCompletions { waiting.append { _ in completion(result) } } else { completion(result) }
        }
    }
    private final class Simulation {
        var lid: Bool? = true
        var date = Date()
        var uptime = 100.0
        func advance(_ seconds: Double) { date.addTimeInterval(seconds); uptime += seconds }
    }
    private var suite: String!
    private var defaults: UserDefaults!
    private var poster: FakePoster!
    private var simulation: Simulation!
    private var messages: [(enabled: Bool, text: String)] = []

    override func setUpWithError() throws {
        suite = "local.rl.lidkeep.thermal-alert-tests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        poster = FakePoster()
        simulation = Simulation()
        messages = []
    }
    override func tearDownWithError() throws {
        drain()
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeController() -> ThermalAlertController {
        let environment = simulation!
        let controller = ThermalAlertController(defaults: defaults, poster: poster, lidReading: { environment.lid },
                                                uptime: { environment.uptime }, wallClock: { environment.date })
        controller.onChange = { [weak self] enabled, message in self?.messages.append((enabled, message)) }
        return controller
    }
    private func drain(rounds: Int = 1) {
        for _ in 0..<rounds {
            let drained = expectation(description: "Main queue delivers poster callbacks")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 2)
        }
    }
    private func status(mode: RunMode = .active, thermal: ThermalLevel = .fair, age: Double = 0) -> RuntimeStatus {
        var status = RuntimeStatus(preferences: Preferences(), mode: mode, reason: "测试", batteryPercent: 80,
                                   onAC: false, thermal: thermal, sleepDisabled: true, verified: true)
        status.updatedAt = simulation.date.addingTimeInterval(-age)
        return status
    }
    /// Mirrors the app heartbeat: one observation every five seconds.
    private func tick(_ controller: ThermalAlertController, _ count: Int, _ make: () -> RuntimeStatus? = { nil }) {
        for _ in 0..<count {
            controller.observe(make())
            drain()
            simulation.advance(5)
        }
    }

    func testDefaultEnabledRequestsAuthorizationOnce() throws {
        let controller = makeController()
        controller.start()
        drain()
        XCTAssertTrue(controller.enabled)
        XCTAssertEqual(poster.authorizationRequests, 1)
        let last = try XCTUnwrap(messages.last)
        XCTAssertTrue(last.enabled)
        XCTAssertTrue(last.text.contains("已允许通知"))
    }

    func testSustainedClosedLidFairPostsOnceAfterFiveMinutes() throws {
        let controller = makeController()
        controller.start()
        drain()
        tick(controller, 60) { self.status() }
        XCTAssertEqual(poster.posts.count, 0, "No reminder before five minutes")
        tick(controller, 1) { self.status() }
        XCTAssertEqual(poster.posts.count, 1)
        let post = try XCTUnwrap(poster.posts.first)
        XCTAssertTrue(post.title.contains("略高"))
        XCTAssertTrue(post.body.contains("5 分钟"))
        XCTAssertTrue(try XCTUnwrap(messages.last).text.contains("上次热状态提醒"))
        tick(controller, 120) { self.status() }
        XCTAssertEqual(poster.posts.count, 1)
    }

    func testStaleStatusProtectedModeOrOpenLidDoesNotPost() {
        let scenarios: [(Bool, () -> RuntimeStatus)] = [
            (true, { self.status(age: 20) }),
            (true, { self.status(mode: .protected) }),
            (false, { self.status() })
        ]
        for (lid, make) in scenarios {
            simulation.lid = lid
            let controller = makeController()
            controller.start()
            drain()
            tick(controller, 80, make)
        }
        XCTAssertEqual(poster.posts.count, 0)
    }

    func testFailedPostRetriesAfterFiveMinutesThenStops() throws {
        poster.failures = ["模拟发送失败"]
        let controller = makeController()
        controller.start()
        drain()
        tick(controller, 61) { self.status() }
        XCTAssertEqual(poster.posts.count, 1)
        XCTAssertTrue(try XCTUnwrap(messages.last).text.contains("模拟发送失败"))
        tick(controller, 59) { self.status() }
        XCTAssertEqual(poster.posts.count, 1, "No retry inside five minutes")
        tick(controller, 1) { self.status() }
        XCTAssertEqual(poster.posts.count, 2)
        XCTAssertTrue(try XCTUnwrap(messages.last).text.contains("上次热状态提醒"))
        tick(controller, 120) { self.status() }
        XCTAssertEqual(poster.posts.count, 2)
    }

    func testDelayedCallbackDoesNotDuplicatePost() throws {
        poster.deferCompletions = true
        let controller = makeController()
        controller.start()
        drain()
        tick(controller, 61) { self.status() }
        XCTAssertEqual(poster.posts.count, 1)
        tick(controller, 120) { self.status() }
        XCTAssertEqual(poster.posts.count, 1, "An in-flight post is not submitted again")
        poster.waiting.removeFirst()(nil)
        drain()
        XCTAssertTrue(try XCTUnwrap(messages.last).text.contains("上次热状态提醒"))
        tick(controller, 120) { self.status() }
        XCTAssertEqual(poster.posts.count, 1)
    }

    func testDisabledPreferencePersistsAndSuppressesPosts() throws {
        let controller = makeController()
        controller.start()
        drain()
        controller.setEnabled(false)
        drain()
        XCTAssertEqual(defaults.object(forKey: "thermalAlertEnabled") as? Bool, false)
        XCTAssertFalse(try XCTUnwrap(messages.last).enabled)
        XCTAssertEqual(try XCTUnwrap(messages.last).text, "已关闭热状态提醒。")
        tick(controller, 120) { self.status() }
        XCTAssertEqual(poster.posts.count, 0)
        let restarted = makeController()
        XCTAssertFalse(restarted.enabled)
        restarted.start()
        drain()
        XCTAssertEqual(poster.authorizationRequests, 1, "Disabled reminders do not ask for permission")
        XCTAssertFalse(try XCTUnwrap(messages.last).enabled)
    }

    func testRestartKeepsThirtyMinuteIntervalAndLastReminderText() throws {
        let controller = makeController()
        controller.start()
        drain()
        tick(controller, 61) { self.status() }
        XCTAssertEqual(poster.posts.count, 1)
        let delivered = try XCTUnwrap(defaults.object(forKey: "thermalAlertLastDelivered") as? Date)
        simulation.advance(delivered.addingTimeInterval(60).timeIntervalSince(simulation.date))
        let soon = makeController()
        soon.start()
        drain()
        XCTAssertTrue(try XCTUnwrap(messages.last).text.contains("上次热状态提醒"))
        tick(soon, 61) { self.status() }
        XCTAssertEqual(poster.posts.count, 1, "A restart one minute later keeps the interval")
        simulation.advance(delivered.addingTimeInterval(31 * 60).timeIntervalSince(simulation.date))
        let later = makeController()
        later.start()
        drain()
        XCTAssertTrue(try XCTUnwrap(messages.last).text.contains("上次热状态提醒"))
        tick(later, 61) { self.status() }
        XCTAssertEqual(poster.posts.count, 2)
    }

    func testTestNotificationBypassesPolicyAndKeepsAutomaticInterval() throws {
        simulation.lid = false
        let controller = makeController()
        controller.start()
        drain()
        controller.sendTest()
        drain(rounds: 3)
        XCTAssertEqual(poster.posts.map(\.title), ["LidKeep 测试通知"])
        XCTAssertNil(defaults.object(forKey: "thermalAlertLastDelivered"), "Test posts are not reminder history")
        simulation.lid = true
        tick(controller, 61) { self.status() }
        XCTAssertEqual(poster.posts.map(\.title), ["LidKeep 测试通知", "合盖运行时系统热状态略高"])
        poster.permission = .denied
        controller.sendTest()
        drain(rounds: 3)
        XCTAssertEqual(poster.posts.count, 2)
        XCTAssertTrue(try XCTUnwrap(messages.last).text.contains("通知权限未开启"))
        poster.permission = .notDetermined
        poster.grantOnRequest = true
        controller.sendTest()
        drain(rounds: 3)
        XCTAssertEqual(poster.authorizationRequests, 2, "Undetermined permission is requested before a test")
        XCTAssertEqual(poster.posts.count, 3)
    }
}
