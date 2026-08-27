import Foundation

enum DirectPasteOrderState: Equatable {
    case recording
    case created
    case sending
    case acknowledgedEventPosted
    case unconfirmed
    case cancelled
}

enum DirectPasteCancellationReason: String, Equatable {
    case emptyTranscription = "empty_transcription"
    case sessionCancelled = "session_cancelled"
    case inputSourceSelectionFailed = "input_source_selection_failed"
    case routeUnavailableBeforeSubmit = "route_unavailable_before_submit"
    case focusReadinessFailed = "focus_readiness_failed"
    case functionKeyPostFailed = "function_key_post_failed"
    case stoppingFocusLost = "stopping_focus_lost"
    case markedTextCommitTimedOut = "marked_text_commit_timed_out"
}

enum DirectPasteLifecycleEvent: String, Equatable {
    case focusReady = "focus_ready"
    case inputSourceReady = "input_source_ready"
    case functionKeyDownPosted = "fn_down_posted"
    case markedTextStarted = "marked_text_started"
    case functionKeyUpPosted = "fn_up_posted"
    case markedTextCommitted = "marked_text_committed"
    case finalTextLocked = "final_text_locked"
}

enum RemoteClipboardTransportEvent: Equatable {
    case responseReceived(httpStatus: Int, durationMilliseconds: Double)
}

@MainActor
final class DirectPasteOrderCoordinator {
    typealias SendOperation = (
        _ text: String,
        _ identity: PasteOrderIdentity,
        _ transportEvent: @escaping (RemoteClipboardTransportEvent) -> Void
    ) async throws -> RemotePasteAcknowledgement

    private let logger: PasteOrderEventLogger
    private let sendOperation: SendOperation
    private let onUnconfirmedCountChanged: (Int) -> Void
    private(set) var controllerSessionId: UUID
    private var nextSequence: Int64 = 1
    private var states: [UUID: DirectPasteOrderState] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var activeIdentities: [UUID: PasteOrderIdentity] = [:]

    init(
        logger: PasteOrderEventLogger,
        controllerSessionId: UUID = UUID(),
        sendOperation: @escaping SendOperation = { text, identity, transportEvent in
            try await RemoteClipboardClient().paste(
                text: text,
                identity: identity,
                onTransportEvent: transportEvent
            )
        },
        onUnconfirmedCountChanged: @escaping (Int) -> Void = { _ in }
    ) {
        self.logger = logger
        self.controllerSessionId = controllerSessionId
        self.sendOperation = sendOperation
        self.onUnconfirmedCountChanged = onUnconfirmedCountChanged
    }

    func beginRecording() -> PasteOrderIdentity {
        let identity = PasteOrderIdentity(
            requestId: UUID(),
            controllerSessionId: controllerSessionId,
            sequence: nextSequence
        )
        nextSequence += 1
        states[identity.requestId] = .recording
        logger.capture(
            identity: identity,
            event: "recording_started",
            protocolVersion: RemoteClipboardClient.protocolVersion
        )
        return identity
    }

    func transcriptionReady(identity: PasteOrderIdentity, textLength: Int) {
        guard states[identity.requestId] == .recording else { return }
        logger.capture(
            identity: identity,
            event: "transcription_ready",
            protocolVersion: RemoteClipboardClient.protocolVersion,
            textLength: textLength
        )
    }

    func recordLifecycleEvent(
        identity: PasteOrderIdentity,
        event: DirectPasteLifecycleEvent,
        textLength: Int? = nil
    ) {
        guard states[identity.requestId] == .recording else { return }
        logger.capture(
            identity: identity,
            event: event.rawValue,
            protocolVersion: RemoteClipboardClient.protocolVersion,
            textLength: textLength
        )
    }

    func submit(
        identity: PasteOrderIdentity,
        text: String,
        targetProcessIdentifier: Int32?,
        targetBundleIdentifier: String?
    ) {
        guard states[identity.requestId] == .recording, !text.isEmpty else { return }
        states[identity.requestId] = .created
        logger.capture(
            identity: identity,
            event: "request_created",
            protocolVersion: RemoteClipboardClient.protocolVersion,
            textLength: text.count,
            targetProcessIdentifier: targetProcessIdentifier,
            targetBundleIdentifier: targetBundleIdentifier
        )
        states[identity.requestId] = .sending

        let requestId = identity.requestId
        activeIdentities[requestId] = identity
        tasks[requestId] = Task { [weak self, logger = self.logger, sendOperation = self.sendOperation] in
            logger.capture(
                identity: identity,
                event: "http_send_started",
                protocolVersion: RemoteClipboardClient.protocolVersion,
                textLength: text.count,
                targetProcessIdentifier: targetProcessIdentifier,
                targetBundleIdentifier: targetBundleIdentifier
            )
            do {
                let acknowledgement = try await sendOperation(text, identity) { transportEvent in
                    switch transportEvent {
                    case let .responseReceived(status, duration):
                        logger.capture(
                            identity: identity,
                            event: "response_received",
                            protocolVersion: RemoteClipboardClient.protocolVersion,
                            textLength: text.count,
                            httpStatus: status,
                            durationMilliseconds: duration
                        )
                    }
                }
                guard let self else { return }
                self.states[requestId] = .acknowledgedEventPosted
                self.logger.capture(
                    identity: identity,
                    event: "ack_validated",
                    protocolVersion: RemoteClipboardClient.protocolVersion,
                    textLength: text.count,
                    targetProcessIdentifier: acknowledgement.targetProcessIdentifier,
                    targetBundleIdentifier: acknowledgement.targetBundleIdentifier,
                    pasteboardChangeCount: acknowledgement.changeCount
                )
                self.tasks[requestId] = nil
                self.activeIdentities[requestId] = nil
                self.publishUnconfirmedCount()
            } catch {
                guard let self else { return }
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    self.states[requestId] = .cancelled
                    self.tasks[requestId] = nil
                    self.activeIdentities[requestId] = nil
                    self.publishUnconfirmedCount()
                    return
                }
                let isTimeout = (error as? URLError)?.code == .timedOut
                if isTimeout {
                    self.logger.capture(
                        identity: identity,
                        event: "timeout",
                        protocolVersion: RemoteClipboardClient.protocolVersion,
                        textLength: text.count,
                        errorCode: Int32(URLError.timedOut.rawValue)
                    )
                }
                self.states[requestId] = .unconfirmed
                let nsErrorCode = (error as NSError).code
                self.logger.capture(
                    identity: identity,
                    event: "unconfirmed",
                    protocolVersion: RemoteClipboardClient.protocolVersion,
                    textLength: text.count,
                    errorCode: (Int(Int32.min)...Int(Int32.max)).contains(nsErrorCode) ? Int32(nsErrorCode) : nil,
                    detailsJSON: Self.safeErrorDetails(error)
                )
                self.tasks[requestId] = nil
                self.activeIdentities[requestId] = nil
                self.publishUnconfirmedCount()
                print("[DirectPasteOrderCoordinator] Paste event unconfirmed requestId=\(requestId.uuidString); later orders remain enabled")
            }
        }
    }

    func abandonRecording(
        identity: PasteOrderIdentity,
        reason: DirectPasteCancellationReason
    ) {
        guard states[identity.requestId] == .recording else { return }
        states[identity.requestId] = .cancelled
        logger.capture(
            identity: identity,
            event: "task_cancelled",
            protocolVersion: RemoteClipboardClient.protocolVersion,
            detailsJSON: Self.cancellationDetails(reason)
        )
    }

    /// Direct HTTP work is cancelled only during actual application shutdown.
    func cancelAllForShutdown() {
        for (requestId, task) in tasks {
            guard let identity = identityForActiveRequest(requestId) else {
                task.cancel()
                continue
            }
            logger.capture(
                identity: identity,
                event: "task_cancelled",
                protocolVersion: RemoteClipboardClient.protocolVersion,
                detailsJSON: "{\"reason\":\"application_shutdown\"}"
            )
            task.cancel()
        }
    }

    func state(for requestId: UUID) -> DirectPasteOrderState? {
        states[requestId]
    }

    var activeRequestCount: Int { tasks.count }
    var unconfirmedRequestCount: Int { states.values.filter { $0 == .unconfirmed }.count }

    private func publishUnconfirmedCount() {
        onUnconfirmedCountChanged(unconfirmedRequestCount)
    }

    private func identityForActiveRequest(_ requestId: UUID) -> PasteOrderIdentity? {
        activeIdentities[requestId]
    }

    private static func safeErrorDetails(_ error: Error) -> String? {
        let type = String(describing: Swift.type(of: error))
        guard let data = try? JSONSerialization.data(withJSONObject: ["error_type": type]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    private static func cancellationDetails(_ reason: DirectPasteCancellationReason) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["reason": reason.rawValue]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }
}
