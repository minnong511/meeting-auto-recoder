import Combine
import Foundation
import RecorderCore

/// Coordinates read-only work on the search actor; UI state never waits for
/// filesystem reads or text normalization on the main actor.
@MainActor
final class MeetingSearchModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    @Published var scope: MeetingSearchScope = .all { didSet { if scope != oldValue { scheduleSearch() } } }
    @Published private(set) var hits: [MeetingSearchHit] = []
    @Published private(set) var isSearching = false
    @Published private(set) var hasSearched = false
    @Published private(set) var wasCancelled = false
    @Published private(set) var warnings: [String] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var totalMatches = 0
    @Published private(set) var selectedSnapshot: MeetingSearchSnapshot?
    @Published private(set) var selectedHit: MeetingSearchHit?
    @Published private(set) var navigationID = UUID()
    @Published private(set) var pendingPlayback: Double?
    @Published private(set) var isLoadingSelection = false
    @Published private(set) var selectionError: String?
    var onLibraryRefresh: (([StoredMeeting]) -> Void)?
    var onSelectionRefresh: ((StoredMeeting) -> Void)?

    private let index = LocalMeetingSearchIndex()
    private var root: URL?
    private var libraryKey = ""
    private var selected: StoredMeeting?
    private var selectionIsLive = false
    private var searchTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var selectionGeneration = UUID()
    private var navigationGeneration = UUID()
    private var lastSearchFinishedAt = Date.distantPast
    private var refreshInterval: TimeInterval = 3

    func updateContext(root: URL?, meetings: [StoredMeeting], activeMeetingID: UUID?) {
        let normalizedRoot = root?.standardizedFileURL
        let changedRoot = normalizedRoot != self.root
        let key = meetings.map { "\($0.id):\($0.directory.path)" }.joined(separator: "|")
        guard changedRoot || key != libraryKey else { return }
        self.root = normalizedRoot
        libraryKey = key
        if changedRoot {
            cancel()
            selectionTask?.cancel()
            selectionGeneration = UUID()
            navigationGeneration = UUID()
            selected = nil
            selectedSnapshot = nil
            selectedHit = nil
            pendingPlayback = nil
            selectionError = nil
            isLoadingSelection = false
            Task { await index.clear() }
        }
        scheduleSearch()
    }

    func runSearch() { scheduleSearch(delay: false) }

    func refresh() {
        if !isSearching && !wasCancelled && Date().timeIntervalSince(lastSearchFinishedAt) >= refreshInterval &&
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleSearch(delay: false, keepResults: true)
        }
        if let selected, !selectionIsLive, selectionTask == nil { readSelection(selected, showLoading: selectedSnapshot == nil) }
    }

    func cancel() {
        stopSearchWork()
        wasCancelled = true
        hasSearched = true
    }

    private func stopSearchWork() {
        searchGeneration = UUID()
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    func suspend() {
        stopSearchWork()
        selectionTask?.cancel()
        selectionTask = nil
        selectionGeneration = UUID()
        navigationGeneration = UUID()
        pendingPlayback = nil
        isLoadingSelection = false
    }

    private func scheduleSearch(delay: Bool = true, keepResults: Bool = false) {
        stopSearchWork()
        wasCancelled = false
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keepResults {
            hits = []; totalMatches = 0; hasSearched = false
            selectedHit = nil
            pendingPlayback = nil
            navigationGeneration = UUID()
        }
        warnings = []
        errorMessage = nil
        guard !text.isEmpty else { return }
        guard text.count <= 256 else {
            errorMessage = "검색어는 256자 이하로 입력해 주세요."
            hasSearched = true
            return
        }
        guard let root else {
            errorMessage = "회의를 저장한 폴더를 먼저 선택해 주세요."
            hasSearched = true
            return
        }
        let request = UUID()
        searchGeneration = request
        let scope = self.scope
        isSearching = true
        searchTask = Task(priority: .utility) { [weak self, index] in
            do {
                if delay { try await Task.sleep(for: .milliseconds(250)) }
                try Task.checkCancellation()
                let response = try await index.search(root: root, query: text, scope: scope)
                try Task.checkCancellation()
                guard let self, self.searchGeneration == request, self.root == root else { return }
                self.hits = response.hits
                self.totalMatches = response.totalMatches
                self.warnings = response.warnings
                self.hasSearched = true
                self.lastSearchFinishedAt = Date()
                self.refreshInterval = response.meetings.count > 200 ? 10 : 3
                self.isSearching = false
                self.searchTask = nil
                self.onLibraryRefresh?(response.meetings)
            } catch is CancellationError {
                guard let self, self.searchGeneration == request else { return }
                self.isSearching = false
                self.searchTask = nil
            } catch {
                guard let self, self.searchGeneration == request, self.root == root else { return }
                self.hits = []
                self.totalMatches = 0
                self.errorMessage = "회의 폴더를 검색할 수 없습니다. 위치와 접근 권한을 확인한 뒤 다시 시도해 주세요. \(error.localizedDescription)"
                self.hasSearched = true
                self.isSearching = false
                self.searchTask = nil
            }
        }
    }

    func loadSelection(_ stored: StoredMeeting?, live: Bool) {
        if selected?.id == stored?.id, selected?.directory == stored?.directory, selectionIsLive == live {
            if let stored, !live, selectedSnapshot == nil, selectionTask == nil { readSelection(stored, showLoading: true) }
            return
        }
        selectionTask?.cancel()
        selectionTask = nil
        selectionGeneration = UUID()
        navigationGeneration = UUID()
        selected = stored
        selectionIsLive = live
        selectedSnapshot = nil
        selectedHit = nil
        pendingPlayback = nil
        selectionError = nil
        isLoadingSelection = false
        guard let stored, !live else { return }
        readSelection(stored, showLoading: true)
    }

    private func readSelection(_ stored: StoredMeeting, showLoading: Bool) {
        guard let root else { return }
        selectionTask?.cancel()
        let request = UUID()
        selectionGeneration = request
        if showLoading { isLoadingSelection = true }
        selectionTask = Task(priority: .utility) { [weak self, index] in
            do {
                let snapshot = try await index.snapshot(root: root, meetingID: stored.id, directory: stored.directory)
                try Task.checkCancellation()
                guard let self, self.selectionGeneration == request, self.root == root else { return }
                let changed = self.selectedSnapshot?.transcript.version != snapshot.transcript.version ||
                    self.selectedSnapshot?.summary?.version != snapshot.summary?.version
                if changed || self.selectedSnapshot == nil { self.selectedSnapshot = snapshot }
                self.onSelectionRefresh?(snapshot.stored)
                if let hit = self.selectedHit {
                    let document = hit.source == .summary ? snapshot.summary : snapshot.transcript
                    let changedHit = hit.source == .title ? hit.title != snapshot.stored.meeting.title : document?.version != hit.documentVersion
                    if changedHit {
                        self.selectedHit = nil
                        self.pendingPlayback = nil
                        self.errorMessage = "문서가 변경되어 이전 검색 위치를 해제했습니다. 다시 검색해 주세요."
                    }
                }
                self.selectionError = nil
                self.isLoadingSelection = false
                self.selectionTask = nil
            } catch is CancellationError {
                guard let self, self.selectionGeneration == request else { return }
                self.isLoadingSelection = false
                self.selectionTask = nil
            } catch {
                guard let self, self.selectionGeneration == request, self.root == root else { return }
                self.selectedSnapshot = nil
                self.selectedHit = nil
                self.pendingPlayback = nil
                self.selectionError = "이 회의를 읽을 수 없습니다. 파일이 이동·삭제되었거나 접근 권한이 변경되었는지 확인해 주세요."
                self.isLoadingSelection = false
                self.selectionTask = nil
            }
        }
    }

    func activate(_ hit: MeetingSearchHit, autoplay: Bool) async -> StoredMeeting? {
        guard let root else { return nil }
        pendingPlayback = nil
        let request = UUID()
        navigationGeneration = request
        selectionTask?.cancel()
        selectionTask = nil
        selectionGeneration = UUID()
        do {
            let (snapshot, validated) = try await index.validate(root: root, hit: hit)
            try Task.checkCancellation()
            guard navigationGeneration == request, self.root == root else { return nil }
            selected = snapshot.stored
            selectionIsLive = false
            selectedSnapshot = snapshot
            onSelectionRefresh?(snapshot.stored)
            selectedHit = validated
            selectionError = nil
            isLoadingSelection = false
            pendingPlayback = autoplay ? validated.playbackStart : nil
            if autoplay && validated.playbackStart == nil {
                errorMessage = "연결된 녹음 파일을 재생할 수 없습니다. 파일 위치와 접근 권한을 확인해 주세요."
            }
            navigationID = UUID()
            return snapshot.stored
        } catch is CancellationError { return nil }
        catch {
            guard navigationGeneration == request, self.root == root else { return nil }
            errorMessage = "검색 결과의 원문이 변경되었거나 이동·삭제되었습니다. 결과를 새로고침한 뒤 다시 선택해 주세요."
            selectedHit = nil
            pendingPlayback = nil
            runSearch()
            // Keep the navigation error visible alongside the fresh results.
            errorMessage = "이전 검색 결과를 열지 않았습니다. 문서가 변경되었거나 이동·삭제되었습니다."
            return nil
        }
    }

    func consumePlayback() -> Double? {
        defer { pendingPlayback = nil }
        return pendingPlayback
    }

    deinit {
        searchTask?.cancel()
        selectionTask?.cancel()
    }
}
