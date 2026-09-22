import AppKit
import SwiftUI
import XCTest
import MacParakeetCore
import MacParakeetViewModels
@testable import MacParakeet

/// Layout contracts for the shared label-options viewport and its editor host.
///
/// These use `NSHostingView` fitting sizes. A SwiftUI `.popover` needs a live
/// AppKit window; creating and closing that private window in XCTest crashed
/// in AppKit's popover appearance observer during teardown.
@MainActor
final class LabelPopoverOptionsViewportTests: XCTestCase {
    private let viewportMaximumHeight: CGFloat = 260

    private struct FilterOptions: View {
        let labels: [String]
        let emptyMessage: String

        var body: some View {
            LabelPopoverOptionsViewport {
                VStack(alignment: .leading, spacing: 2) {
                    if labels.isEmpty {
                        Text(emptyMessage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                    } else {
                        ForEach(labels, id: \.self) { label in
                            Text(label)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 5)
                        }
                    }
                }
            }
            .frame(width: 320)
        }
    }

    private final class StaticTypeRepository: MeetingTypeRepositoryProtocol, @unchecked Sendable {
        func save(_ meetingType: MeetingType) throws {}
        func fetch(id: UUID) throws -> MeetingType? { nil }
        func fetchAll(includeArchived: Bool) throws -> [MeetingType] { [] }
        func setArchived(id: UUID, isArchived: Bool) throws {}
        func delete(id: UUID) throws -> Bool { false }
    }

    private final class StaticLabelRepository: MeetingLabelRepositoryProtocol, @unchecked Sendable {
        let labels: [MeetingLabel]

        init(labels: [MeetingLabel]) {
            self.labels = labels
        }

        func save(_ label: MeetingLabel) throws {}
        func fetch(id: UUID) throws -> MeetingLabel? { labels.first { $0.id == id } }
        func fetchAll(includeArchived: Bool) throws -> [MeetingLabel] { labels }
        func setArchived(id: UUID, isArchived: Bool) throws {}
        func delete(id: UUID) throws -> Bool { false }
    }

    private final class StaticClassificationService: MeetingClassificationServiceProtocol, @unchecked Sendable {
        let classification: MeetingClassification

        init(classification: MeetingClassification) {
            self.classification = classification
        }

        func classification(for transcriptionId: UUID) throws -> MeetingClassification { classification }
        func setMeetingType(_ meetingTypeId: UUID?, for transcriptionId: UUID) async throws {}
        func replaceLabels(_ labelIds: Set<UUID>, for transcriptionId: UUID) async throws {}
        func update(
            meetingTypeId: UUID?,
            labelIds: Set<UUID>,
            for transcriptionId: UUID
        ) async throws {}
    }

    private func fittingHeight<Content: View>(of content: Content, width: CGFloat = 320) -> CGFloat {
        let host = NSHostingView(rootView: content.frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private func makeEditor(labelCount: Int) async -> MeetingClassificationEditor {
        let labels = (1...labelCount).map { MeetingLabel(name: "Label \($0)", sortOrder: $0) }
        let transcription = Transcription(
            fileName: "Layout fixture",
            status: .completed,
            sourceType: .meeting
        )
        let viewModel = MeetingClassificationViewModel()
        viewModel.configure(
            typeRepository: StaticTypeRepository(),
            labelRepository: StaticLabelRepository(labels: labels),
            service: StaticClassificationService(
                classification: MeetingClassification(meetingType: nil, labels: labels)
            )
        )
        await viewModel.loadOptions().value
        await viewModel.loadClassification(for: transcription.id).value

        return MeetingClassificationEditor(
            transcription: transcription,
            viewModel: viewModel,
            onDismiss: {},
            onManage: {}
        )
    }

    func testEmptyAndFewOptionsUseNaturalHeights() {
        let emptyHeight = fittingHeight(of: FilterOptions(labels: [], emptyMessage: "No selected labels"))
        let fewHeight = fittingHeight(
            of: FilterOptions(
                labels: ["Research", "Planning", "Follow-up"],
                emptyMessage: "No labels match missing"
            )
        )

        XCTAssertGreaterThan(emptyHeight, 0)
        XCTAssertLessThan(emptyHeight, viewportMaximumHeight)
        XCTAssertGreaterThan(fewHeight, emptyHeight)
        XCTAssertLessThan(fewHeight, viewportMaximumHeight)
    }

    func testManyOptionsUseBoundedScrollableHeight() {
        let optionsHeight = fittingHeight(
            of: FilterOptions(
                labels: (1...40).map { "Label \($0)" },
                emptyMessage: "No labels match missing"
            )
        )

        XCTAssertEqual(optionsHeight, viewportMaximumHeight, accuracy: 1)
    }

    func testActualEditorFitsSelectedLabelsWithoutPopoverDefaultHeight() async {
        let shortEditor = await makeEditor(labelCount: 2)
        let longEditor = await makeEditor(labelCount: 40)
        let shortHeight = fittingHeight(of: shortEditor, width: 340)
        let longHeight = fittingHeight(of: longEditor, width: 340)

        XCTAssertGreaterThan(shortHeight, 100)
        XCTAssertLessThan(shortHeight, longHeight)
        XCTAssertLessThanOrEqual(longHeight - shortHeight, viewportMaximumHeight)
    }
}
