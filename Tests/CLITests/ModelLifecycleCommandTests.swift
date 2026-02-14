import ArgumentParser
import XCTest
@testable import CLI

final class ModelLifecycleCommandTests: XCTestCase {
    func testValidatedAttemptsRejectsZero() {
        XCTAssertThrowsError(try validatedAttempts(0)) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testValidatedAttemptsAcceptsPositiveValues() throws {
        XCTAssertEqual(try validatedAttempts(1), 1)
        XCTAssertEqual(try validatedAttempts(5), 5)
    }

    func testModelsStatusParsesTarget() throws {
        let command = try ModelsCommand.Status.parse(["--target", "llm"])
        XCTAssertEqual(command.target, .llm)
    }

    func testModelsWarmUpParsesTargetAndAttempts() throws {
        let command = try ModelsCommand.WarmUp.parse(["--target", "stt", "--attempts", "4"])
        XCTAssertEqual(command.target, .stt)
        XCTAssertEqual(command.attempts, 4)
    }

    func testModelsRepairDefaultsToAllAndThreeAttempts() throws {
        let command = try ModelsCommand.Repair.parse([])
        XCTAssertEqual(command.target, .all)
        XCTAssertEqual(command.attempts, 3)
    }

    func testHealthParsesRepairFlags() throws {
        let command = try HealthCommand.parse(["--repair-models", "--repair-attempts", "6"])
        XCTAssertTrue(command.repairModels)
        XCTAssertEqual(command.repairAttempts, 6)
    }
}
