import Foundation
import Testing
@testable import EdgePanel

@Suite("AskUserQuestion gate")
struct QuestionTimeoutTests {
    @Test("timeout falls back instead of fabricating an empty allowed answer")
    @MainActor
    func timeoutReturnsNil() async throws {
        setenv("EDGEPANEL_QUESTION_TIMEOUT", "0", 1)
        defer { unsetenv("EDGEPANEL_QUESTION_TIMEOUT") }

        let questions: [[String: Any]] = [[
            "question": "Deploy now?",
            "header": "Deploy",
            "multiSelect": false,
            "options": [["label": "Yes"], ["label": "No"]],
        ]]
        let data = try JSONSerialization.data(withJSONObject: questions)
        let state = EdgePanelState()

        let result = await state.requestQuestionDecision(questionsData: data, project: "Test")
        #expect(result == nil)
        #expect(state.pendingQuestion == nil)
    }
}
