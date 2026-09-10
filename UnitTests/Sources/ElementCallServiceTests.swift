//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Clocks
@testable import ElementX
import PushKit
import XCTest

@MainActor
class ElementCallServiceTests: XCTestCase {
    var callProvider: CXProviderMock!
    var currentDate: Date!
    var testClock: TestClock<Duration>!
    var pushRegistry: PKPushRegistry!
    
    var service: ElementCallService!
    
    override func tearDown() {
        callProvider = nil
        currentDate = nil
        testClock = nil
        pushRegistry = nil
    }
    
    func testIncomingCall() async {
        setupService()
        
        XCTAssertFalse(callProvider.reportNewIncomingCallWithUpdateCompletionCalled)
        
        let expectation = XCTestExpectation(description: "Call accepted")
        
        let pkPushPayloadMock = PKPushPayloadMock().updatingExpiration(currentDate, lifetime: 30)
        
        service.pushRegistry(pushRegistry, didReceiveIncomingPushWith: pkPushPayloadMock, for: .voIP) {
            expectation.fulfill()
        }
        
        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertTrue(callProvider.reportNewIncomingCallWithUpdateCompletionCalled)
    }
    
    func disabled_testCallIsTimingOut() async {
        setupService()
        
        XCTAssertFalse(callProvider.reportNewIncomingCallWithUpdateCompletionCalled)
        let expectation = XCTestExpectation(description: "Call accepted")
        
        let pushPayload = PKPushPayloadMock().updatingExpiration(currentDate, lifetime: 20)
        
        service.pushRegistry(pushRegistry,
                             didReceiveIncomingPushWith: pushPayload,
                             for: .voIP) {
            expectation.fulfill()
        }
        
        let expectation2 = XCTestExpectation(description: "Call ended unanswered")
        callProvider.reportCallWithEndedAtReasonClosure = { _, _, reason in
            if reason == .unanswered {
                expectation2.fulfill()
            } else {
                XCTFail("Call should have ended as unanswered")
            }
        }
        
        await fulfillment(of: [expectation], timeout: 1)
        
        // advance past the timeout
        await testClock.advance(by: .seconds(30))
        await fulfillment(of: [expectation2], timeout: 1)
    }
    
    func testExpiredRingLifetimeIsIgnored() {
        setupService()
   
        XCTAssertFalse(callProvider.reportNewIncomingCallWithUpdateCompletionCalled)
        
        let pushPayload = PKPushPayloadMock().updatingExpiration(currentDate, lifetime: 20)
        
        currentDate = currentDate.addingTimeInterval(60)
        
        service.pushRegistry(pushRegistry,
                             didReceiveIncomingPushWith: pushPayload,
                             for: .voIP) { }
        sleep(20)
        
        // ⚠️ Просроченный вызов человеку не показывается, но CallKit о нём всё же
        // уведомляют фиктивным звонком — иначе iOS ругается на пуш без звонка.
        // Проверяем именно ПОКАЗ, а не сам факт обращения.
        XCTAssertEqual(показаноЧеловеку, 0)
    }
    
    func disabled_testLifetimeIsCapped() async throws {
        setupService()
        
        let expectation = expectation(description: "Call has ended unanswered")
        callProvider.reportCallWithEndedAtReasonClosure = { _, _, reason in
            if reason == .unanswered {
                expectation.fulfill()
            } else {
                XCTFail("Call should have ended as unanswered")
            }
        }
        
        XCTAssertFalse(callProvider.reportNewIncomingCallWithUpdateCompletionCalled)
        
        let pushPayload = PKPushPayloadMock().updatingExpiration(currentDate, lifetime: 300)
        
        service.pushRegistry(pushRegistry,
                             didReceiveIncomingPushWith: pushPayload,
                             for: .voIP) { }
        
        // Advance past the max timeout but below the 300
        await testClock.advance(by: .seconds(100))
        await fulfillment(of: [expectation], timeout: 1)
    }
    
    // MARK: - STMOB-87 (второй заход): пометка о звонке протухает по часам

    /// Сколько звонков человек РЕАЛЬНО увидел.
    ///
    /// ⚠️ Считать все обращения к CallKit нельзя: подавленный дубль и просроченный
    /// вызов тоже докладываются — фиктивным звонком, который гасится в тот же миг
    /// (`reportAndCancelFakeCall`). Он нужен, чтобы iOS не ругалась на пуш без
    /// звонка, но человеку не показывается. Отличаем по опознавателю «silent»,
    /// который этому фиктивному вызову и присваивают.
    ///
    /// ⚠️ Считаем СВОИМ перехватом, а не списком вызовов у заглушки: та пишет
    /// список отложенно, через главную очередь, и в синхронной проверке он всегда
    /// пуст. На этом я уже обожглась — проверки показывали ноль там, где звонок
    /// был.
    private var показаноЧеловеку = 0
    
    /// ⚠️ Второй звонок В ТУ ЖЕ КОМНАТУ через сутки ОБЯЗАН зазвонить.
    ///
    /// Как терялся звонок у владельца (лог nse-events 223): 09.09 в 16:27 пришёл
    /// неотвеченный вызов и оставил пометку; 10.09 в 14:22 новый вызов сравнили с
    /// ней и погасили как «повтор» — `duplicate ring, keeping existing callKitID`
    /// с тем же самым идентификатором 22 часа спустя. На Android тот же звонок
    /// пришёл нормально, то есть сервер и пуш были ни при чём.
    ///
    /// Пометку снимала отложенная задача, но она живёт в процессе приложения,
    /// а процесс в фоне замораживают: сон не идёт, задача не просыпается.
    /// Поэтому проверка тут идёт ПО ЧАСАМ (`currentDate`), а не сном теста —
    /// сном мы бы проверили ровно то, что и сломалось.
    func testЗвонокЧерезСуткиВТуЖеКомнатуНеСчитаетсяПовтором() {
        setupService()
        
        let первый = PKPushPayloadMock().updatingExpiration(currentDate, lifetime: 30)
        service.pushRegistry(pushRegistry, didReceiveIncomingPushWith: первый, for: .voIP) { }
        XCTAssertEqual(показаноЧеловеку, 1, "первый звонок обязан показаться")
        
        // Ровно тот разрыв, что был у владельца: 22 часа.
        currentDate = currentDate.addingTimeInterval(22 * 60 * 60)
        
        let второй = PKPushPayloadMock().updatingExpiration(currentDate, lifetime: 30)
        service.pushRegistry(pushRegistry, didReceiveIncomingPushWith: второй, for: .voIP) { }
        
        XCTAssertEqual(показаноЧеловеку, 2, "звонок через сутки — не повтор вчерашнего; пометка обязана протухнуть")
    }
    
    /// ⚠️ Настоящий повтор гасить НАДО. Synapse рассылает один и тот же вызов
    /// несколькими событиями, и телефон получает 3-4 пуша за пару секунд: без
    /// этой ветки на экране появлялось бы несколько звонков подряд.
    /// Проверка нужна рядом с предыдущей, чтобы починка «протухания» не снесла
    /// дедупликацию заодно.
    func testДваПушаПодрядОстаютсяОднимЗвонком() {
        setupService()
        
        let первый = PKPushPayloadMock().updatingExpiration(currentDate, lifetime: 30)
        service.pushRegistry(pushRegistry, didReceiveIncomingPushWith: первый, for: .voIP) { }
        XCTAssertEqual(показаноЧеловеку, 1)
        
        currentDate = currentDate.addingTimeInterval(2)
        
        let второй = PKPushPayloadMock().updatingExpiration(currentDate, lifetime: 30)
        service.pushRegistry(pushRegistry, didReceiveIncomingPushWith: второй, for: .voIP) { }
        
        XCTAssertEqual(показаноЧеловеку, 1, "два пуша об одном вызове — один звонок на экране")
    }
    
    /// ⚠️ У протухшей пометки есть долг: пропущенный звонок. CallKit его не
    /// показывал, а задача, которая обычно шлёт `.missedCall`, не проснулась —
    /// поэтому владелец не увидел ни звонка, ни пропущенного. Сообщить обязаны
    /// в тот момент, когда протухание обнаружено.
    func testПротухшаяПометкаДокладываетПропущенный() {
        setupService()
        
        let первый = PKPushPayloadMock().updatingExpiration(currentDate, lifetime: 30)
        service.pushRegistry(pushRegistry, didReceiveIncomingPushWith: первый, for: .voIP) { }
        
        var пропущенных = 0
        let подписка = service.actions.sink { action in
            if case .missedCall = action { пропущенных += 1 }
        }
        defer { подписка.cancel() }
        
        currentDate = currentDate.addingTimeInterval(22 * 60 * 60)
        let второй = PKPushPayloadMock().updatingExpiration(currentDate, lifetime: 30)
        service.pushRegistry(pushRegistry, didReceiveIncomingPushWith: второй, for: .voIP) { }
        
        XCTAssertEqual(пропущенных, 1, "вчерашний неотвеченный обязан попасть в историю")
    }
    
    // MARK: - Helpers
    
    private func setupService() {
        pushRegistry = PKPushRegistry(queue: nil)
        callProvider = CXProviderMock(.init())
        currentDate = Date()
        testClock = TestClock()
        let dateProvider: () -> Date = {
            self.currentDate
        }
        показаноЧеловеку = 0
        callProvider.reportNewIncomingCallWithUpdateCompletionClosure = { [weak self] _, update, completion in
            if update.remoteHandle?.value != "silent" { self?.показаноЧеловеку += 1 }
            // ⚠️ Ответить обязаны: настоящий CallKit подтверждает показ, и на этом
            // подтверждении держится вся дальнейшая цепочка звонка. Без ответа
            // соседняя проверка зависала на ожидании.
            completion(nil)
        }
        service = ElementCallService(callProvider: callProvider, timeProvider: TimeProvider(clock: testClock, now: dateProvider))
    }
}

private class PKPushPayloadMock: PKPushPayload {
    var dict: [AnyHashable: Any] = [:]
    
    override init() {
        dict[ElementCallServiceNotificationKey.roomID.rawValue] = "!room:example.com"
        dict[ElementCallServiceNotificationKey.roomDisplayName.rawValue] = "welcome"
        dict[ElementCallServiceNotificationKey.rtcNotifyEventID.rawValue] = "$000"
        dict[ElementCallServiceNotificationKey.expirationDate.rawValue] = Date(timeIntervalSince1970: 10)
    }
    
    override var dictionaryPayload: [AnyHashable: Any] {
        dict
    }
    
    func updatingExpiration(_ from: Date, lifetime: TimeInterval) -> Self {
        dict[ElementCallServiceNotificationKey.expirationDate.rawValue] = from.addingTimeInterval(lifetime)
        return self
    }
}
