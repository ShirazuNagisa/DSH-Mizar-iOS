//
//  SurveysView.swift
//  DSH-Mizar
//
//  The questionnaires the operator dispatched, and the form that pays for one.
//
//  Two screens rather than one: the list is a directory of what is open (with
//  what each one pays and whether this account already answered), and the form
//  is a single questionnaire. A survey is not a settings switch -- it is a
//  thing with a beginning, a middle and a reward -- so it gets the navigation
//  a form deserves.
//
//  The form is plain `List` and system controls: a picker per single choice,
//  rows with checkmarks per multi-choice, and a growing text field per written
//  answer. Nothing here is drawn by hand, which is also what makes it usable
//  with VoiceOver without a second layout.
//

import MizarKit
import SwiftUI

// MARK: - List

/// Every open questionnaire, and the ones already answered.
struct SurveysView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.account.surveyPhase == .failed, model.account.surveys.isEmpty {
                Section {
                    Label {
                        Text(model.account.surveyError ?? String(localized: "Questionnaires are unavailable right now. Try again later."))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Theme.waiting)
                    }
                    .font(.subheadline)
                    .accessibilityIdentifier("surveys.error")
                }
                .listRowBackground(Color.clear)
            } else if model.account.surveys.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        if model.account.surveyPhase == .loading {
                            ProgressView().controlSize(.small)
                        }
                        Text(
                            model.account.surveyPhase == .loading
                                ? String(localized: "Loading questionnaires…")
                                : String(localized: "There are no questionnaires right now."),
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("surveys.empty")
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(model.account.surveys) { survey in
                        NavigationLink {
                            SurveyDetailView(survey: survey)
                        } label: {
                            SurveyRow(survey: survey)
                        }
                        .accessibilityIdentifier("surveys.row.\(survey.id)")
                    }
                } header: {
                    SettingsSectionHeader("Questionnaires")
                } footer: {
                    Text("Answering one adds the reward it shows to your account. Each account can answer each questionnaire once.")
                }
            }
        }
        .navigationTitle(Text("Questionnaires"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.account.loadSurveys() }
        .refreshable { await model.account.loadSurveys() }
        .accessibilityIdentifier("surveys.list")
    }
}

/// One row: what it asks, what it pays, and whether it is done.
private struct SurveyRow: View {
    let survey: Survey

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: survey.completed ? "checkmark.seal.fill" : "checklist")
                .font(.body)
                .foregroundStyle(survey.completed ? Theme.waiting : Theme.accentText)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(survey.title)
                    .foregroundStyle(Theme.accentText)
                    .lineLimit(2)
                if !survey.summary.isEmpty {
                    Text(survey.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(
                survey.completed
                    ? String(localized: "Done")
                    : String(format: String(localized: "%lld days"), survey.rewardDays),
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(survey.completed ? Color.secondary : Theme.accentText)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Form

/// One questionnaire: its questions, the answers, and the reward.
struct SurveyDetailView: View {
    let survey: Survey

    @Environment(AppModel.self) private var model
    /// Answers by question id. A question that was not answered is absent.
    @State private var answers: [String: SurveyAnswerValue] = [:]
    @State private var submitting = false
    /// The days granted, once the relay accepted the submission.
    @State private var reward: Int?
    /// The refusal, when the relay said no.
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(survey.title)
                        .font(.title3.weight(.semibold))
                    if !survey.summary.isEmpty {
                        Text(survey.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Label(
                        String(format: String(localized: "Reward: %lld days of paid access"), survey.rewardDays),
                        systemImage: "star.circle",
                    )
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.accentText)
                }
                .padding(.vertical, 4)
            }

            Section {
                ForEach(survey.questions) { question in
                    questionView(question)
                }
            } header: {
                SettingsSectionHeader("Questions")
            } footer: {
                Text("Answers are sent to the Mizar survey server and are not used to train anything in this app.")
            }

            Section {
                if let reward {
                    Label(
                        String(format: String(localized: "Thank you — %lld days have been added."), reward),
                        systemImage: "checkmark.seal.fill",
                    )
                    .font(.subheadline)
                    .foregroundStyle(Theme.accentText)
                    .accessibilityIdentifier("survey.reward")
                } else if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Theme.failed)
                        .accessibilityIdentifier("survey.error")
                }
                if survey.completed, reward == nil {
                    Label(String(localized: "You have already answered this questionnaire."), systemImage: "checkmark.seal")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("survey.completed")
                } else if reward == nil {
                    Button {
                        submit()
                    } label: {
                        HStack {
                            Spacer()
                            if submitting {
                                ProgressView().controlSize(.small)
                            }
                            Text(submitting ? String(localized: "Sending…") : String(localized: "Submit"))
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit || submitting)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .accessibilityIdentifier("survey.submit")
                }
            }
        }
        .navigationTitle(Text("Questionnaire"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("survey.detail")
        .onChange(of: model.account.surveys) { _, list in
            // The controller reloads the list after a submission; if this
            // survey is now marked done and the reward is known, leave the form
            // in its answered state rather than offering Submit twice.
            guard reward == nil, let updated = list.first(where: { $0.id == survey.id }), updated.completed else {
                return
            }
            failure = nil
        }
    }

    /// Whether every required question has an answer.
    private var canSubmit: Bool {
        survey.questions.allSatisfy { question in
            guard question.required else { return true }
            guard let value = answers[question.id] else { return false }
            switch value {
            case .text(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .choices(let choices): return !choices.isEmpty
            }
        }
    }

    /// One question, drawn as the control its type asks for.
    @ViewBuilder
    private func questionView(_ question: SurveyQuestion) -> some View {
        switch question.type {
        case .single:
            Picker(selection: singleBinding(question)) {
                ForEach(question.options) { option in
                    Text(option.label).tag(option.id)
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(question.prompt)
                        .font(.body)
                    if question.required {
                        Text("Required")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("survey.question.\(question.id)")

        case .multi:
            VStack(alignment: .leading, spacing: 6) {
                Text(question.prompt)
                    .font(.body)
                ForEach(question.options) { option in
                    Button {
                        toggle(option.id, for: question)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isChosen(option.id, for: question) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isChosen(option.id, for: question) ? Theme.accentText : .secondary)
                            Text(option.label)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("survey.option.\(question.id).\(option.id)")
                    .accessibilityAddTraits(isChosen(option.id, for: question) ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("survey.question.\(question.id)")

        case .text:
            VStack(alignment: .leading, spacing: 6) {
                Text(question.prompt)
                    .font(.body)
                TextField(
                    String(localized: "Your answer"),
                    text: textBinding(question),
                    axis: .vertical,
                )
                .lineLimit(2...8)
                .textInputAutocapitalization(.sentences)
                .accessibilityIdentifier("survey.answer.\(question.id)")
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Bindings

    /// A single choice as a `String`; empty until one is picked.
    private func singleBinding(_ question: SurveyQuestion) -> Binding<String> {
        Binding(
            get: {
                if case .text(let value) = answers[question.id] { return value }
                return ""
            },
            set: { answers[question.id] = .text($0) },
        )
    }

    /// A written answer.
    private func textBinding(_ question: SurveyQuestion) -> Binding<String> {
        Binding(
            get: {
                if case .text(let value) = answers[question.id] { return value }
                return ""
            },
            set: { answers[question.id] = .text($0) },
        )
    }

    /// Toggle one option in a multi-select answer.
    private func toggle(_ option: String, for question: SurveyQuestion) {
        var current: [String] = if case .choices(let values) = answers[question.id] { values } else { [] }
        if let index = current.firstIndex(of: option) {
            current.remove(at: index)
        } else {
            current.append(option)
        }
        answers[question.id] = .choices(current)
    }

    /// Whether one option is chosen.
    private func isChosen(_ option: String, for question: SurveyQuestion) -> Bool {
        if case .choices(let values) = answers[question.id] { return values.contains(option) }
        return false
    }

    // MARK: - Submit

    private func submit() {
        guard canSubmit, !submitting else { return }
        submitting = true
        failure = nil
        Task {
            defer { submitting = false }
            let answers = survey.questions.compactMap { question -> SurveyAnswer? in
                guard let value = self.answers[question.id] else { return nil }
                // A single choice with no selection is not an answer.
                if case .text(let text) = value, question.type != .text,
                   text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return nil
                }
                return SurveyAnswer(questionId: question.id, value: value)
            }
            guard let days = await model.account.submitSurvey(survey, answers: answers) else {
                failure = model.account.lastError ?? String(localized: "The questionnaire could not be submitted.")
                return
            }
            reward = days
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}
