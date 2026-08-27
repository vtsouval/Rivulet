// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import XCTest
@testable import Rivulet

final class JellyfinLiveTVClassificationTests: XCTestCase {
    func testMajorGreekChannelsRemainInGreeceLineup() {
        let names = [
            "ERT1", "ERT2", "ERT3", "ANT1", "MEGA Channel", "Star Channel",
            "Alpha TV", "SKAI", "OPEN Beyond", "MAK TV", "Kontra Channel", "Vouli",
            "Action 24", "Naftemporiki TV", "COSMOTE Cinema 1", "Nova Cinema 1"
        ]

        for name in names {
            let result = IOSJellyfinLiveTVClassifier.classify(channel: channel(name), program: nil)
            XCTAssertEqual(result.country, .greece, "Expected \(name) in the Greece lineup")
        }
    }

    func testAllServerTagsParticipateInCountryClassification() {
        let value = channel("Example", group: "Entertainment · Greece · HD")
        XCTAssertEqual(IOSJellyfinLiveTVClassifier.classify(channel: value, program: nil).country, .greece)
    }

    func testProgramTitleCannotRelabelChannelCountry() {
        let foreign = channel("NPO 1", group: "Netherlands")
        let greekNamedProgram = program(channelID: foreign.id, title: "Greek News")
        XCTAssertEqual(
            IOSJellyfinLiveTVClassifier.classify(channel: foreign, program: greekNamedProgram).country,
            .netherlands
        )
    }

    func testGreekSportsFeedKeepsCountryAndSportsCategory() {
        let sports = channel("COSMOTE Sport 1", group: "Sports · Greece")
        let classification = IOSJellyfinLiveTVClassifier.classify(channel: sports, program: nil)
        XCTAssertEqual(classification.country, .greece)
        XCTAssertEqual(classification.category, .sports)
    }

    func testRepresentativeCountriesRemainDistinct() {
        XCTAssertEqual(classification("NPO 1", "Netherlands").country, .netherlands)
        XCTAssertEqual(classification("ABC Australia", "Australia").country, .australia)
        XCTAssertEqual(classification("KBS World", "Korea").country, .korea)
        XCTAssertEqual(classification("BBC One", "United Kingdom").country, .unitedKingdom)
        XCTAssertEqual(classification("CBS USA", "United States").country, .unitedStates)
    }

    private func classification(_ name: String, _ group: String) -> IOSLiveTVClassification {
        IOSJellyfinLiveTVClassifier.classify(channel: channel(name, group: group), program: nil)
    }

    private func channel(_ name: String, group: String? = nil) -> UnifiedChannel {
        UnifiedChannel(
            id: "test:\(name)",
            sourceType: .jellyfin,
            sourceId: "test",
            name: name,
            tvgId: name,
            groupTitle: group
        )
    }

    private func program(channelID: String, title: String) -> UnifiedProgram {
        UnifiedProgram(
            id: "program",
            channelId: channelID,
            title: title,
            startTime: Date().addingTimeInterval(-60),
            endTime: Date().addingTimeInterval(60)
        )
    }
}
