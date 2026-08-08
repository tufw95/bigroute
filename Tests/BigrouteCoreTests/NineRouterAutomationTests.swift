import Foundation
import Testing
@testable import BigrouteCore

@Test func nineRouterAutomationPolicyUsesZeroAndNonzeroThresholds() {
    #expect(NineRouterAutomationPolicy.desiredActiveState(
        currentlyActive: true,
        measurement: .init(remaining: 0, unlimited: false)
    ) == false)
    #expect(NineRouterAutomationPolicy.desiredActiveState(
        currentlyActive: false,
        measurement: .init(remaining: 0, unlimited: false)
    ) == nil)
    #expect(NineRouterAutomationPolicy.desiredActiveState(
        currentlyActive: false,
        measurement: .init(remaining: 0.01, unlimited: false)
    ) == true)
    #expect(NineRouterAutomationPolicy.desiredActiveState(
        currentlyActive: true,
        measurement: .init(remaining: 75, unlimited: false)
    ) == nil)
    #expect(NineRouterAutomationPolicy.desiredActiveState(
        currentlyActive: true,
        measurement: .init(remaining: .nan, unlimited: false)
    ) == nil)
    #expect(NineRouterAutomationPolicy.desiredActiveState(
        currentlyActive: true,
        measurement: .init(remaining: -0.01, unlimited: false)
    ) == nil)
    #expect(NineRouterAutomationPolicy.desiredActiveState(
        currentlyActive: false,
        measurement: .init(remaining: 100.01, unlimited: false)
    ) == nil)
    #expect(NineRouterAutomationPolicy.desiredActiveState(
        currentlyActive: true,
        measurement: .init(remaining: 0, unlimited: true)
    ) == nil)
    #expect(NineRouterAutomationPolicy.desiredActiveState(
        currentlyActive: true,
        measurement: nil
    ) == nil)
}

@Test func nineRouterAutomationRejectsUnavailableAndUnmeasuredQuota() {
    #expect(NineRouterAutomationPolicy.authoritativeMeasurement(
        for: automationAccount(rawID: "raw-1", remaining: 0, status: "unavailable")
    ) == nil)
    #expect(NineRouterAutomationPolicy.authoritativeMeasurement(
        for: automationAccount(rawID: "raw-1", remaining: 0, errorCode: "auth_required")
    ) == nil)
    #expect(NineRouterAutomationPolicy.authoritativeMeasurement(
        for: automationAccount(rawID: "raw-1", remaining: 0, total: 0)
    ) == nil)
    #expect(NineRouterAutomationPolicy.authoritativeMeasurement(
        for: automationAccount(rawID: "raw-1", remaining: 0, unlimited: true)
    ) == nil)
    #expect(NineRouterAutomationPolicy.authoritativeMeasurement(
        for: automationAccount(rawID: "raw-1", remaining: .nan)
    ) == nil)
    #expect(NineRouterAutomationPolicy.authoritativeMeasurement(
        for: automationAccount(rawID: "raw-1", remaining: -1)
    ) == nil)
    #expect(NineRouterAutomationPolicy.authoritativeMeasurement(
        for: automationAccount(rawID: "raw-1", remaining: 101)
    ) == nil)
    #expect(NineRouterAutomationPolicy.authoritativeMeasurement(
        for: automationAccount(rawID: "raw-1", remaining: 0, resetAt: "")
    ) == nil)
    #expect(NineRouterAutomationPolicy.authoritativeMeasurement(
        for: automationAccount(rawID: "raw-1", remaining: 0, usedOverride: 0)
    ) == nil)
    #expect(NineRouterAutomationPolicy.authoritativeMeasurement(
        for: automationAccount(
            rawID: "raw-1",
            remaining: 75,
            additionalQuotas: [CodexQuotaWindow(
                key: "Session",
                used: 25,
                total: 100,
                remaining: 75,
                resetAt: nil,
                unlimited: false
            )]
        )
    ) == nil)
}

@Test func nineRouterAutomationUsesTheLowestMeasuredQuotaWindow() {
    let weekly = CodexQuotaWindow(
        key: "weekly",
        used: 100,
        total: 100,
        remaining: 0,
        resetAt: nil,
        unlimited: false
    )
    let measurement = NineRouterAutomationPolicy.authoritativeMeasurement(
        for: automationAccount(rawID: "raw-1", remaining: 75, additionalQuotas: [weekly])
    )
    #expect(measurement?.remaining == 0)
}

@Test func nineRouterPublicAccountIDMatchesServerHash() {
    #expect(NineRouterAutomationService.publicAccountID(for: "raw-1") == "e72e2581cffd8fef")
}

@Test func nineRouterManagementBaseURLStripsKnownQuotaSuffixes() throws {
    let APIQuota = try #require(URL(string: "https://router.example.com/team/api/v1/quota"))
    let quota = try #require(URL(string: "https://router.example.com/team/v1/quota"))
    #expect(try NineRouterAutomationService.managementBaseURL(from: APIQuota).absoluteString == "https://router.example.com/team")
    #expect(try NineRouterAutomationService.managementBaseURL(from: quota).absoluteString == "https://router.example.com/team")
}

@Test func nineRouterAutomationDetectsDuplicateControllersByManagementEndpoint() throws {
    let first = CustomQuotaProvider(
        name: "Primary",
        endpoint: "https://router.example.com/team/api/v1/quota",
        apiKind: .nineRouter,
        isAutomaticAccountRoutingEnabled: true
    )
    let second = CustomQuotaProvider(
        name: "Secondary",
        endpoint: "https://ROUTER.example.com:443/team/v1/quota",
        apiKind: .nineRouter,
        isAutomaticAccountRoutingEnabled: true
    )
    let disabled = CustomQuotaProvider(
        name: "Disabled",
        endpoint: "https://router.example.com/team",
        apiKind: .nineRouter,
        isEnabled: false,
        isAutomaticAccountRoutingEnabled: true
    )

    #expect(NineRouterAutomationService.conflictingAutomationProviderIDs(in: [first, second, disabled]) == [first.id, second.id])
}

@Test func nineRouterAutomationDeactivatesExhaustedActiveAccount() async throws {
    let rawID = "raw-1"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1}}"#),
        .json(#"{"connection":{"id":"raw-1","isActive":false}}"#)
    ])
    let service = NineRouterAutomationService(transport: transport)
    let report = try await service.reconcile(
        baseURL: try #require(URL(string: "https://router.example.com/team/api/v1/quota")),
        managementPassword: "  exact password  ",
        activeQuota: [automationAccount(rawID: rawID, remaining: 0)]
    )

    #expect(report.changes == [NineRouterAutomationChange(
        connectionID: rawID,
        publicAccountID: NineRouterAutomationService.publicAccountID(for: rawID),
        kind: .deactivated,
        remaining: 0
    )])
    #expect(report.updatedState.autoDisabledConnectionIDs == [rawID])
    #expect(report.updatedState.deactivationWindows[rawID]?.keys.sorted() == ["session", "weekly"])
    #expect(report.warnings.isEmpty)

    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["POST", "GET", "PUT"])
    #expect(requests[0].url?.path == "/team/api/auth/login")
    #expect(requests[1].url?.path == "/team/api/providers/client")
    #expect(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(
        URLQueryItem(name: "pageSize", value: "500")
    ) == true)
    #expect(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(
        URLQueryItem(name: "provider", value: "codex")
    ) == true)
    #expect(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(
        URLQueryItem(name: "accountStatus", value: "all")
    ) == true)
    #expect(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.first(
        where: { $0.name == "bigroute_inventory" }
    )?.value?.isEmpty == false)
    #expect(requests[2].url?.path == "/team/api/providers/raw-1")
    #expect(requests[1].value(forHTTPHeaderField: "Cookie") == "auth_token=test-token")
    #expect(requests[2].value(forHTTPHeaderField: "Cookie") == "auth_token=test-token")
    #expect(try requestJSON(requests[0])["password"] as? String == "  exact password  ")
    #expect(try requestJSON(requests[2])["isActive"] as? Bool == false)
}

@Test func nineRouterAutomationRejectsDuplicateActiveQuotaRows() async throws {
    let rawID = "raw-1"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1}}"#)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [
            automationAccount(rawID: rawID, remaining: 0),
            automationAccount(rawID: rawID, remaining: 75)
        ]
    )

    #expect(report.changes.isEmpty)
    #expect(report.updatedState.autoDisabledConnectionIDs.isEmpty)
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET"])
}

@Test func nineRouterAutomationReactivatesOnlyOwnedInactiveAccount() async throws {
    let rawID = "raw-1"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":false}],"pagination":{"totalPages":1}}"#),
        .json(usageJSON(sessionRemaining: 75, weeklyRemaining: 75)),
        .json(#"{"connection":{"id":"raw-1","isActive":true}}"#)
    ])
    let service = NineRouterAutomationService(transport: transport)
    let report = try await service.reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [],
        state: ownedAutomationState(rawID)
    )

    #expect(report.updatedState.autoDisabledConnectionIDs.isEmpty)
    #expect(report.changes.first?.kind == .activated)
    #expect(report.changes.first?.remaining == 75)
    #expect(report.observations.first?.publicAccountID == NineRouterAutomationService.publicAccountID(for: rawID))
    #expect(report.observations.first?.measurement.remaining == 75)
    let requests = await transport.requests
    #expect(requests.map(\.url?.path) == [
        "/api/auth/login", "/api/providers/client", "/api/usage/raw-1", "/api/providers/raw-1"
    ])
    let usageRequest = requests[2]
    let usageQuery = URLComponents(url: usageRequest.url!, resolvingAgainstBaseURL: false)?.queryItems
    #expect(usageQuery?.first(where: { $0.name == "bigroute_refresh" })?.value?.isEmpty == false)
    #expect(usageRequest.value(forHTTPHeaderField: "Cache-Control") == "no-cache, no-store, max-age=0")
    #expect(usageRequest.value(forHTTPHeaderField: "Pragma") == "no-cache")
    #expect(usageRequest.value(forHTTPHeaderField: "Expires") == "0")
    #expect(try requestJSON(requests[3])["isActive"] as? Bool == true)
}

@Test func nineRouterAutomationKeepsOwnedInactiveAccountDisabledAtZero() async throws {
    let rawID = "raw-1"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":false}],"pagination":{"totalPages":1}}"#),
        .json(usageJSON(sessionRemaining: 0, weeklyRemaining: 75))
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [],
        state: ownedAutomationState(rawID)
    )

    #expect(report.changes.isEmpty)
    #expect(report.updatedState.autoDisabledConnectionIDs == [rawID])
    #expect(report.observations.first?.measurement.remaining == 0)
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET", "GET"])
}

@Test func nineRouterAutomationRequiresEveryInactiveQuotaWindowToBeNonzero() async throws {
    let rawID = "raw-1"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":false}],"pagination":{"totalPages":1}}"#),
        .json(usageJSON(sessionRemaining: 75, weeklyRemaining: 0))
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [],
        state: ownedAutomationState(rawID)
    )

    #expect(report.changes.isEmpty)
    #expect(report.updatedState.autoDisabledConnectionIDs == [rawID])
    #expect(report.observations.first?.measurement.remaining == 0)
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET", "GET"])
}

@Test func nineRouterAutomationLeavesManuallyDisabledAccountAlone() async throws {
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"manual","provider":"codex","authType":"oauth","isActive":false}],"pagination":{"totalPages":1}}"#)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: []
    )

    #expect(report.changes.isEmpty)
    #expect(report.updatedState.autoDisabledConnectionIDs.isEmpty)
    #expect((await transport.requests).count == 2)
}

@Test func nineRouterAutomationFailsClosedWhenConnectionStateIsMissing() async throws {
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"manual","provider":"codex","authType":"oauth"}],"pagination":{"totalPages":1}}"#)
    ])
    do {
        _ = try await NineRouterAutomationService(transport: transport).reconcile(
            baseURL: try #require(URL(string: "https://router.example.com")),
            managementPassword: "password",
            activeQuota: [automationAccount(rawID: "manual", remaining: 0)]
        )
        Issue.record("Expected unknown connection state to stop reconciliation.")
    } catch let error as NineRouterAutomationError {
        #expect(error == .invalidResponse)
    }
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET"])
}

@Test func nineRouterAutomationFailsClosedForDuplicateOrUnsafeConnectionIDs() async throws {
    for inventory in [
        #"{"connections":[{"id":"duplicate","provider":"codex","authType":"oauth","isActive":true},{"id":"duplicate","provider":"codex","authType":"oauth","isActive":false}],"pagination":{"totalPages":1}}"#,
        #"{"connections":[{"id":"../providers","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1}}"#
    ] {
        let transport = NineRouterMockTransport(responses: [.login(), .json(inventory)])
        do {
            _ = try await NineRouterAutomationService(transport: transport).reconcile(
                baseURL: try #require(URL(string: "https://router.example.com")),
                managementPassword: "password",
                activeQuota: []
            )
            Issue.record("Expected ambiguous inventory to fail closed.")
        } catch let error as NineRouterAutomationError {
            #expect(error == .invalidResponse)
        }
        #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET"])
    }
}

@Test func nineRouterAutomationRejectsCachedOrIncompleteInventory() async throws {
    let rawID = "owned"
    let inventory = #"{"connections":[{"id":"owned","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1}}"#
    let responses: [NineRouterHTTPResponse] = [
        NineRouterHTTPResponse(statusCode: 200, headers: ["Age": "1"], body: Data(inventory.utf8)),
        .json(#"{"connections":[{"id":"owned","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1,"totalItems":2}}"#),
        .json(#"{"connections":[{"id":"owned","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":0}}"#),
        .json(#"{"connections":[{"id":"owned","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1.5}}"#),
        .json(#"{"connections":[{"id":"owned","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1},"cache":"stale"}"#)
    ]

    for response in responses {
        let transport = NineRouterMockTransport(responses: [.login(), response])
        do {
            _ = try await NineRouterAutomationService(transport: transport).reconcile(
                baseURL: try #require(URL(string: "https://router.example.com")),
                managementPassword: "password",
                activeQuota: [],
                state: ownedAutomationState(rawID)
            )
            Issue.record("Expected incomplete or cached inventory to fail closed.")
        } catch let error as NineRouterAutomationError {
            #expect([.invalidResponse, .staleQuota].contains(error))
        }
        #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET"])
    }
}

@Test func nineRouterAutomationLoadsAndChecksEveryInventoryPage() async throws {
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"first","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"page":1,"totalPages":2,"totalItems":2}}"#),
        .json(#"{"connections":[{"id":"second","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"page":2,"totalPages":2,"totalItems":2}}"#)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: []
    )

    #expect(report.inspectedConnectionCount == 2)
    let requests = await transport.requests
    #expect(requests.map(\.url?.path) == ["/api/auth/login", "/api/providers/client", "/api/providers/client"])
    let pages = requests.dropFirst().compactMap { request in
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value
    }
    #expect(pages == ["1", "2"])
}

@Test func nineRouterAutomationRejectsConflictingTotalPages() async throws {
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"first","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"page":1,"totalPages":2}}"#),
        .json(#"{"connections":[{"id":"second","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"page":2,"totalPages":1}}"#)
    ])

    do {
        _ = try await NineRouterAutomationService(transport: transport).reconcile(
            baseURL: try #require(URL(string: "https://router.example.com")),
            managementPassword: "password",
            activeQuota: []
        )
        Issue.record("Expected conflicting inventory page counts to fail closed.")
    } catch let error as NineRouterAutomationError {
        #expect(error == .invalidResponse)
    }

    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["POST", "GET", "GET"])
    #expect(requests.map(\.url?.path) == [
        "/api/auth/login", "/api/providers/client", "/api/providers/client"
    ])
}

@Test func nineRouterAutomationRetiresOwnershipForDeletedConnection() async throws {
    let rawID = "deleted"
    let recorder = AutomationStateRecorder()
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[],"pagination":{"totalPages":1}}"#)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [],
        state: ownedAutomationState(rawID),
        persistState: { recorder.record($0) }
    )

    #expect(report.updatedState.autoDisabledConnectionIDs.isEmpty)
    #expect(report.updatedState.deactivationWindows.isEmpty)
    #expect(recorder.states.last?.autoDisabledConnectionIDs.isEmpty == true)
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET"])
}

@Test func nineRouterAutomationDoesNotReactivateBeforeResetEpochAdvances() async throws {
    let rawID = "raw-1"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":false}],"pagination":{"totalPages":1}}"#),
        .json(usageJSON(sessionRemaining: 75, weeklyRemaining: 75, sessionResetOffset: -60 * 60, weeklyResetOffset: -60 * 60))
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [],
        state: ownedAutomationState(rawID)
    )

    #expect(report.changes.isEmpty)
    #expect(report.updatedState.autoDisabledConnectionIDs == [rawID])
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET", "GET"])
}

@Test func nineRouterAutomationDoesNotReactivateLegacyOwnershipWithoutResetEpoch() async throws {
    let rawID = "raw-1"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":false}],"pagination":{"totalPages":1}}"#),
        .json(usageJSON(sessionRemaining: 75, weeklyRemaining: 75))
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [],
        state: NineRouterAutomationState(
            autoDisabledConnectionIDs: [rawID],
            managementEndpointIdentity: "https://router.example.com"
        )
    )

    #expect(report.changes.isEmpty)
    #expect(report.updatedState.autoDisabledConnectionIDs == [rawID])
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET", "GET"])
}

@Test func nineRouterAutomationRejectsUpstreamUnavailableUsageMessage() async throws {
    let rawID = "raw-1"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":false}],"pagination":{"totalPages":1}}"#),
        .json(#"{"message":"Codex connected. Usage API temporarily unavailable (429)."}"#)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [],
        state: ownedAutomationState(rawID)
    )

    #expect(report.changes.isEmpty)
    #expect(report.updatedState.autoDisabledConnectionIDs == [rawID])
    #expect(report.warnings.first?.error == .rateLimited)
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET", "GET"])
}

@Test func nineRouterAutomationRejectsIncompletePositiveUsage() async throws {
    let rawID = "raw-1"
    let resetAt = isoDate(offset: 60 * 60)
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":false}],"pagination":{"totalPages":1}}"#),
        .json(#"{"quotas":{"session":{"total":100,"remaining":75,"resetAt":"\#(resetAt)","unlimited":false},"weekly":{"used":25,"total":100,"remaining":75,"resetAt":"\#(resetAt)","unlimited":false}}}"#)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [],
        state: ownedAutomationState(rawID)
    )

    #expect(report.changes.isEmpty)
    #expect(report.updatedState.autoDisabledConnectionIDs == [rawID])
    #expect(report.warnings.first?.error == .invalidResponse)
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET", "GET"])
}

@Test func nineRouterAutomationRejectsPartialUsageResponse() async throws {
    let rawID = "raw-1"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":false}],"pagination":{"totalPages":1}}"#),
        .json(usageJSON(sessionRemaining: 75, weeklyRemaining: 75), statusCode: 206)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [],
        state: ownedAutomationState(rawID)
    )

    #expect(report.changes.isEmpty)
    #expect(report.updatedState.autoDisabledConnectionIDs == [rawID])
    #expect(report.warnings.first?.error == .invalidResponse)
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET", "GET"])
}

@Test func nineRouterAutomationRejectsCachedUsageResponse() async throws {
    let rawID = "raw-1"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":false}],"pagination":{"totalPages":1}}"#),
        NineRouterHTTPResponse(
            statusCode: 200,
            headers: ["X-Cache": "Hit from cloudfront"],
            body: Data(usageJSON(sessionRemaining: 75, weeklyRemaining: 75).utf8)
        )
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [],
        state: ownedAutomationState(rawID)
    )

    #expect(report.changes.isEmpty)
    #expect(report.updatedState.autoDisabledConnectionIDs == [rawID])
    #expect(report.warnings.first?.error == .staleQuota)
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET", "GET"])
}

@Test func nineRouterAutomationRejectsNestedStaleCacheAndUnavailableStatus() async throws {
    let rawID = "raw-1"
    let staleBody = String(
        usageJSON(sessionRemaining: 75, weeklyRemaining: 75).dropLast()
    ) + ",\"cache\":{\"state\":\"stale\"}}"
    let staleTransport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":false}],"pagination":{"totalPages":1}}"#),
        .json(String(staleBody))
    ])
    let staleReport = try await NineRouterAutomationService(transport: staleTransport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [],
        state: ownedAutomationState(rawID)
    )
    #expect(staleReport.changes.isEmpty)
    #expect(staleReport.warnings.first?.error == .staleQuota)

    let unavailableBody = String(
        usageJSON(sessionRemaining: 75, weeklyRemaining: 75).dropLast()
    ) + ",\"status\":\"unavailable\"}"
    let unavailableTransport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":false}],"pagination":{"totalPages":1}}"#),
        .json(String(unavailableBody))
    ])
    let unavailableReport = try await NineRouterAutomationService(transport: unavailableTransport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [],
        state: ownedAutomationState(rawID)
    )
    #expect(unavailableReport.changes.isEmpty)
    #expect(unavailableReport.warnings.first?.error == .quotaUnavailable)

    let unknownCacheBody = String(
        usageJSON(sessionRemaining: 75, weeklyRemaining: 75).dropLast()
    ) + ",\"cache\":{\"state\":\"mystery\"}}"
    let unknownCacheTransport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":false}],"pagination":{"totalPages":1}}"#),
        .json(unknownCacheBody)
    ])
    let unknownCacheReport = try await NineRouterAutomationService(
        transport: unknownCacheTransport
    ).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [],
        state: ownedAutomationState(rawID)
    )
    #expect(unknownCacheReport.changes.isEmpty)
    #expect(unknownCacheReport.warnings.first?.error == .invalidResponse)
}

@Test func nineRouterAutomationRejectsMalformedOrPartialUsageMetadata() async throws {
    let rawID = "raw-1"
    let baseUsage = String(usageJSON(sessionRemaining: 75, weeklyRemaining: 75).dropLast())
    let invalidSuffixes = [
        #","cache":{"state":"miss","available":false}}"#,
        #","cache":{"state":"miss","status":"unavailable"}}"#,
        #","cache":{"state":0}}"#,
        #","cache":"stale"}"#,
        #","partial":true}"#,
        #","complete":false}"#,
        #","error":{"code":"upstream_failed"}}"#
    ]

    for suffix in invalidSuffixes {
        let transport = NineRouterMockTransport(responses: [
            .login(),
            .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":false}],"pagination":{"totalPages":1}}"#),
            .json(baseUsage + suffix)
        ])
        let report = try await NineRouterAutomationService(transport: transport).reconcile(
            baseURL: try #require(URL(string: "https://router.example.com")),
            managementPassword: "password",
            activeQuota: [],
            state: ownedAutomationState(rawID)
        )

        #expect(report.changes.isEmpty)
        #expect(report.updatedState.autoDisabledConnectionIDs == [rawID])
        #expect(report.warnings.count == 1)
    }
}

@Test func nineRouterAutomationRejectsCaseVariantDuplicateUsageWindows() async throws {
    let rawID = "raw-1"
    let resetAt = isoDate(offset: 60 * 60)
    let usage = #"{"quotas":{"session":{"used":25,"total":100,"remaining":75,"resetAt":"\#(resetAt)","unlimited":false},"Session":{"used":25,"total":100,"remaining":75,"resetAt":"\#(resetAt)","unlimited":false},"weekly":{"used":25,"total":100,"remaining":75,"resetAt":"\#(resetAt)","unlimited":false}}}"#
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":false}],"pagination":{"totalPages":1}}"#),
        .json(usage)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [],
        state: ownedAutomationState(rawID)
    )

    #expect(report.changes.isEmpty)
    #expect(report.warnings.first?.error == .invalidResponse)
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET", "GET"])
}

@Test func nineRouterAutomationDoesNotVerifyDefinitiveClientMutationFailure() async throws {
    let rawID = "raw-1"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1}}"#),
        NineRouterHTTPResponse(statusCode: 422)
    ])
    let recorder = AutomationStateRecorder()
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [automationAccount(rawID: rawID, remaining: 0)],
        persistState: { recorder.record($0) }
    )

    #expect(report.changes.isEmpty)
    #expect(report.updatedState.autoDisabledConnectionIDs.isEmpty)
    #expect(report.warnings.first?.error == .clientError(422))
    #expect(recorder.states.map(\.autoDisabledConnectionIDs) == [[rawID], []])
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET", "PUT"])
}

@Test func nineRouterAutomationVerifiesTimeoutLikeClientMutationFailure() async throws {
    let rawID = "raw-1"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1}}"#),
        NineRouterHTTPResponse(statusCode: 408),
        .json(#"{"connection":{"id":"raw-1","isActive":false}}"#)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [automationAccount(rawID: rawID, remaining: 0)]
    )

    #expect(report.changes.first?.kind == .deactivated)
    #expect(report.updatedState.autoDisabledConnectionIDs == [rawID])
    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["POST", "GET", "PUT", "GET"])
    let verificationQuery = URLComponents(
        url: requests[3].url!,
        resolvingAgainstBaseURL: false
    )?.queryItems
    #expect(verificationQuery?.first(where: { $0.name == "bigroute_verify" })?.value?.isEmpty == false)
    #expect(requests[3].value(forHTTPHeaderField: "Cache-Control") == "no-cache, no-store, max-age=0")
}

@Test func nineRouterAutomationRetainsOwnershipWhenVerificationIsCached() async throws {
    let rawID = "raw-1"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1}}"#),
        NineRouterHTTPResponse(statusCode: 500),
        NineRouterHTTPResponse(
            statusCode: 200,
            headers: ["Age": "1"],
            body: Data(#"{"connection":{"id":"raw-1","isActive":true}}"#.utf8)
        )
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [automationAccount(rawID: rawID, remaining: 0)]
    )

    #expect(report.updatedState.autoDisabledConnectionIDs == [rawID])
    #expect(report.changes.isEmpty)
    #expect(report.warnings.first?.error == .serverError(500))
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET", "PUT", "GET"])
}

@Test func nineRouterAutomationDoesNotReleaseOwnershipForPendingAsyncActivation() async throws {
    let rawID = "raw-1"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":false}],"pagination":{"totalPages":1}}"#),
        .json(usageJSON(sessionRemaining: 75, weeklyRemaining: 75)),
        .json(#"{"connection":{"id":"raw-1","isActive":true}}"#, statusCode: 202),
        .json(#"{"connection":{"id":"raw-1","isActive":false}}"#)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [],
        state: ownedAutomationState(rawID)
    )

    #expect(report.updatedState.autoDisabledConnectionIDs == [rawID])
    #expect(report.changes.isEmpty)
    #expect(report.warnings.first?.error == .invalidResponse)
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET", "GET", "PUT", "GET"])
}

@Test func nineRouterAutomationRetainsOwnershipForPendingAsyncDeactivation() async throws {
    let rawID = "raw-1"
    let recorder = AutomationStateRecorder()
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1}}"#),
        .json(#"{"success":true,"connection":{"id":"raw-1","isActive":false}}"#, statusCode: 202),
        .json(#"{"connection":{"id":"raw-1","isActive":true}}"#)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [automationAccount(rawID: rawID, remaining: 0)],
        persistState: { recorder.record($0) }
    )

    #expect(report.updatedState.autoDisabledConnectionIDs == [rawID])
    #expect(report.changes.isEmpty)
    #expect(report.warnings.first?.error == .invalidResponse)
    #expect(recorder.states.map(\.autoDisabledConnectionIDs) == [[rawID]])
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET", "PUT", "GET"])
}

@Test func nineRouterAutomationDoesNotTrustExplicitlyFailedMutationBody() async throws {
    let rawID = "raw-1"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1}}"#),
        .json(#"{"success":false,"connection":{"id":"raw-1","isActive":false}}"#),
        .json(#"{"connection":{"id":"raw-1","isActive":true}}"#)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [automationAccount(rawID: rawID, remaining: 0)]
    )

    #expect(report.updatedState.autoDisabledConnectionIDs.isEmpty)
    #expect(report.changes.isEmpty)
    #expect(report.warnings.first?.error == .invalidResponse)
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET", "PUT", "GET"])
}

@Test func nineRouterAutomationNeverMutatesNonCodexProviders() async throws {
    let rawID = "omni-1"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"omni-1","provider":"omni","authType":"oauth","isActive":true}],"pagination":{"totalPages":1}}"#)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [automationAccount(rawID: rawID, remaining: 0)]
    )

    #expect(report.changes.isEmpty)
    #expect(report.inspectedConnectionCount == 0)
    #expect((await transport.requests).count == 2)
}

@Test func nineRouterAutomationKeepsOwnershipWhenUsageFails() async throws {
    let rawID = "raw-1"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":false}],"pagination":{"totalPages":1}}"#),
        NineRouterHTTPResponse(statusCode: 500)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [],
        state: ownedAutomationState(rawID)
    )

    #expect(report.updatedState.autoDisabledConnectionIDs == [rawID])
    #expect(report.changes.isEmpty)
    #expect(report.warnings == [NineRouterAutomationWarning(
        connectionID: rawID,
        operation: .usage,
        error: .serverError(500)
    )])
}

@Test func nineRouterAutomationPreservesSuccessfulStateOnLaterRateLimit() async throws {
    let firstID = "first"
    let secondID = "second"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"first","provider":"codex","authType":"oauth","isActive":true},{"id":"second","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1}}"#),
        .json(#"{"connection":{"id":"first","isActive":false}}"#),
        NineRouterHTTPResponse(statusCode: 429)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [
            automationAccount(rawID: firstID, remaining: 0),
            automationAccount(rawID: secondID, remaining: 0)
        ]
    )

    // The second intent is persisted before its PUT so a committed-but-ambiguous
    // write can still be recovered on the next reconciliation.
    #expect(report.updatedState.autoDisabledConnectionIDs == [firstID, secondID])
    #expect(report.changes.map(\.connectionID) == [firstID])
    #expect(report.warnings == [NineRouterAutomationWarning(
        connectionID: secondID,
        operation: .update,
        error: .rateLimited
    )])
}

@Test func nineRouterAutomationRelogsInOnlyOnceAfterUnauthorizedSession() async throws {
    let transport = NineRouterMockTransport(responses: [
        .login(cookie: "old-token"),
        NineRouterHTTPResponse(statusCode: 401),
        .login(cookie: "new-token"),
        .json(#"{"connections":[],"pagination":{"totalPages":1}}"#)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: []
    )

    #expect(report.changes.isEmpty)
    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["POST", "GET", "POST", "GET"])
    #expect(requests[1].value(forHTTPHeaderField: "Cookie") == "auth_token=old-token")
    #expect(requests[3].value(forHTTPHeaderField: "Cookie") == "auth_token=new-token")
}

@Test func nineRouterAutomationFallsBackToLegacyProviderListOn404() async throws {
    let transport = NineRouterMockTransport(responses: [
        .login(),
        NineRouterHTTPResponse(statusCode: 404),
        .json(#"{"connections":[]}"#)
    ])
    _ = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: []
    )
    #expect((await transport.requests).map(\.url?.path) == [
        "/api/auth/login", "/api/providers/client", "/api/providers"
    ])
}

@Test func nineRouterAutomationDoesNotRetryRejectedDashboardPassword() async throws {
    let transport = NineRouterMockTransport(responses: [
        NineRouterHTTPResponse(statusCode: 401)
    ])
    do {
        _ = try await NineRouterAutomationService(transport: transport).reconcile(
            baseURL: try #require(URL(string: "https://router.example.com")),
            managementPassword: "wrong-password",
            activeQuota: []
        )
        Issue.record("Expected the rejected dashboard password to stop reconciliation.")
    } catch let error as NineRouterAutomationError {
        #expect(error == .unauthorized)
    }
    #expect((await transport.requests).count == 1)
}

@Test func nineRouterAutomationRejectsSuccessfulLoginWithoutCookie() async throws {
    let transport = NineRouterMockTransport(responses: [
        .json(#"{"success":true,"mustChangePassword":false}"#)
    ])
    do {
        _ = try await NineRouterAutomationService(transport: transport).reconcile(
            baseURL: try #require(URL(string: "https://router.example.com")),
            managementPassword: "password",
            activeQuota: []
        )
        Issue.record("Expected a cookie-less login response to be rejected.")
    } catch let error as NineRouterAutomationError {
        #expect(error == .invalidAuthenticationResponse)
    }
    #expect((await transport.requests).count == 1)
}

@Test func nineRouterAutomationRejectsRequiredPasswordChange() async throws {
    let transport = NineRouterMockTransport(responses: [
        NineRouterHTTPResponse(
            statusCode: 200,
            headers: ["Set-Cookie": "auth_token=test-token; Path=/; HttpOnly"],
            body: Data(#"{"success":true,"mustChangePassword":true}"#.utf8)
        )
    ])
    do {
        _ = try await NineRouterAutomationService(transport: transport).reconcile(
            baseURL: try #require(URL(string: "https://router.example.com")),
            managementPassword: "password",
            activeQuota: []
        )
        Issue.record("Expected a required dashboard password change to stop automation.")
    } catch let error as NineRouterAutomationError {
        #expect(error == .mustChangePassword)
    }
    #expect((await transport.requests).count == 1)
}

@Test func nineRouterAutomationVerifiesAmbiguousSuccessfulMutation() async throws {
    let rawID = "raw-1"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1}}"#),
        .json(#"{"ok":true}"#),
        .json(#"{"connection":{"id":"raw-1","isActive":false}}"#)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [automationAccount(rawID: rawID, remaining: 0)]
    )

    #expect(report.changes.first?.kind == .deactivated)
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET", "PUT", "GET"])
}

@Test func nineRouterAutomationPersistsOwnershipBeforeDeactivation() async throws {
    let rawID = "raw-1"
    let recorder = AutomationStateRecorder()
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1}}"#),
        .json(#"{"connection":{"id":"raw-1","isActive":false}}"#)
    ])
    _ = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [automationAccount(rawID: rawID, remaining: 0)],
        persistState: { recorder.record($0) }
    )

    #expect(recorder.states.first?.autoDisabledConnectionIDs == [rawID])
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET", "PUT"])
}

@Test func nineRouterAutomationReusesDashboardSessionAcrossRefreshes() async throws {
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[],"pagination":{"totalPages":1}}"#),
        .json(#"{"connections":[],"pagination":{"totalPages":1}}"#)
    ])
    let service = NineRouterAutomationService(transport: transport)
    let baseURL = try #require(URL(string: "https://router.example.com"))

    _ = try await service.reconcile(
        baseURL: baseURL,
        managementPassword: "password",
        activeQuota: []
    )
    _ = try await service.reconcile(
        baseURL: baseURL,
        managementPassword: "password",
        activeQuota: []
    )

    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["POST", "GET", "GET"])
    #expect(requests[2].value(forHTTPHeaderField: "Cookie") == "auth_token=test-token")
}

@Test func nineRouterAutomationPersistsOwnershipReleaseWhenServerShowsAccountActive() async throws {
    let rawID = "raw-1"
    let recorder = AutomationStateRecorder()
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1}}"#)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [automationAccount(rawID: rawID, remaining: 75)],
        state: ownedAutomationState(rawID),
        persistState: { recorder.record($0) }
    )

    #expect(report.updatedState.autoDisabledConnectionIDs.isEmpty)
    #expect(recorder.states.map(\.autoDisabledConnectionIDs) == [[]])
    #expect(report.changes.isEmpty)
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET"])
}

@Test func nineRouterAutomationDoesNotReleaseOwnedActiveAccountWithoutResetQualifiedQuota() async throws {
    let rawID = "raw-1"
    let recorder = AutomationStateRecorder()
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1}}"#)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [],
        state: ownedAutomationState(rawID),
        persistState: { recorder.record($0) }
    )

    #expect(report.updatedState.autoDisabledConnectionIDs == [rawID])
    #expect(recorder.states.isEmpty)
    #expect(report.changes.isEmpty)
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET"])
}

@Test func nineRouterAutomationStopsIfOwnershipReleaseCannotPersist() async throws {
    let rawID = "raw-1"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1}}"#)
    ])

    do {
        _ = try await NineRouterAutomationService(transport: transport).reconcile(
            baseURL: try #require(URL(string: "https://router.example.com")),
            managementPassword: "password",
            activeQuota: [automationAccount(rawID: rawID, remaining: 75)],
            state: ownedAutomationState(rawID),
            persistState: { _ in throw NineRouterAutomationError.statePersistenceFailed }
        )
        Issue.record("Expected ownership release persistence to fail closed.")
    } catch let error as NineRouterAutomationError {
        #expect(error == .statePersistenceFailed)
    }
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET"])
}

@Test func nineRouterAutomationRollsBackOwnershipAfterDefinitiveFailure() async throws {
    let rawID = "raw-1"
    let recorder = AutomationStateRecorder()
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1}}"#),
        NineRouterHTTPResponse(statusCode: 403)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [automationAccount(rawID: rawID, remaining: 0)],
        persistState: { recorder.record($0) }
    )

    #expect(recorder.states.map(\.autoDisabledConnectionIDs) == [[rawID], []])
    #expect(report.updatedState.autoDisabledConnectionIDs.isEmpty)
    #expect(report.changes.isEmpty)
    #expect(report.warnings == [NineRouterAutomationWarning(
        connectionID: rawID,
        operation: .update,
        error: .forbidden
    )])
}

@Test func nineRouterAutomationRetainsOwnershipWhenVerificationStillShowsOldState() async throws {
    let rawID = "raw-1"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1}}"#),
        NineRouterHTTPResponse(statusCode: 500),
        .json(#"{"connection":{"id":"raw-1","isActive":true}}"#)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [automationAccount(rawID: rawID, remaining: 0)]
    )

    #expect(report.updatedState.autoDisabledConnectionIDs == [rawID])
    #expect(report.changes.isEmpty)
    #expect(report.warnings.first?.error == .serverError(500))
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET", "PUT", "GET"])
}

@Test func nineRouterAutomationRetainsOwnershipWhenMutationOutcomeIsAmbiguous() async throws {
    let rawID = "raw-1"
    let transport = NineRouterMockTransport(responses: [
        .login(),
        .json(#"{"connections":[{"id":"raw-1","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1}}"#),
        NineRouterHTTPResponse(statusCode: 500),
        NineRouterHTTPResponse(statusCode: 503)
    ])
    let report = try await NineRouterAutomationService(transport: transport).reconcile(
        baseURL: try #require(URL(string: "https://router.example.com")),
        managementPassword: "password",
        activeQuota: [automationAccount(rawID: rawID, remaining: 0)]
    )

    #expect(report.updatedState.autoDisabledConnectionIDs == [rawID])
    #expect(report.changes.isEmpty)
    #expect(report.warnings.first?.error == .serverError(500))
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET", "PUT", "GET"])
}

@Test func nineRouterAutomationTreatsCancelledTransportAsCancellationWithoutVerification() async throws {
    let rawID = "raw-1"
    let recorder = AutomationStateRecorder()
    let transport = NineRouterCancellationTransport(rawID: rawID)

    do {
        _ = try await NineRouterAutomationService(transport: transport).reconcile(
            baseURL: try #require(URL(string: "https://router.example.com")),
            managementPassword: "password",
            activeQuota: [automationAccount(rawID: rawID, remaining: 0)],
            persistState: { recorder.record($0) }
        )
        Issue.record("Expected the cancelled request to cancel reconciliation.")
    } catch is CancellationError {
        // Expected: cancellation must not be converted into an ambiguous mutation.
    }

    #expect(recorder.states.first?.autoDisabledConnectionIDs == [rawID])
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET", "PUT"])
}

@Test func nineRouterAutomationStopsWhenCancelledTransportReturnsAResponse() async throws {
    let rawID = "raw-1"
    let recorder = AutomationStateRecorder()
    let transport = NineRouterCancelledResponseTransport(rawID: rawID)
    let task = Task {
        try await NineRouterAutomationService(transport: transport).reconcile(
            baseURL: try #require(URL(string: "https://router.example.com")),
            managementPassword: "password",
            activeQuota: [automationAccount(rawID: rawID, remaining: 0)],
            persistState: { recorder.record($0) }
        )
    }

    await transport.waitUntilPutStarts()
    task.cancel()
    await transport.releasePut()
    do {
        _ = try await task.value
        Issue.record("Expected cancellation after the PUT response.")
    } catch is CancellationError {
        // Expected: a late HTTP response must not start mutation verification.
    }

    #expect(recorder.states.first?.autoDisabledConnectionIDs == [rawID])
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET", "PUT"])
}

@Test func nineRouterAutomationSerializesConcurrentReconciliations() async throws {
    let transport = NineRouterBlockingLoginTransport()
    let service = NineRouterAutomationService(transport: transport)
    let baseURL = try #require(URL(string: "https://router.example.com"))
    let first = Task {
        try await service.reconcile(
            baseURL: baseURL,
            managementPassword: "password",
            activeQuota: []
        )
    }
    await transport.waitUntilLoginStarts()
    let second = Task {
        try await service.reconcile(
            baseURL: baseURL,
            managementPassword: "password",
            activeQuota: []
        )
    }

    try await Task.sleep(for: .milliseconds(50))
    #expect(!(await transport.didOverlapWhileLoginBlocked))
    await transport.releaseLogin()
    _ = try await first.value
    _ = try await second.value
    #expect((await transport.requests).map(\.httpMethod) == ["POST", "GET", "GET"])
}

@Test func codexQuotaFreshnessRejectsStaleAndMissingMetadata() throws {
    let freshDate = ISO8601DateFormatter().string(from: Date())
    let staleDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-6 * 60))
    func response(generatedAt: String, cacheState: String?) throws -> CodexQuotaResponse {
        let cache = cacheState.map { ",\"cache\":{\"state\":\"\($0)\"}" } ?? ""
        let json = #"{"object":"list","generatedAt":"\#(generatedAt)","summary":{"accounts":0,"availableAccounts":0,"unavailableAccounts":0,"lowestRemaining":null},"data":[]\#(cache)}"#
        return try JSONDecoder().decode(CodexQuotaResponse.self, from: Data(json.utf8))
    }
    let fresh = try JSONDecoder().decode(
        CodexQuotaResponse.self,
        from: Data(#"{"object":"list","generatedAt":"\#(freshDate)","summary":{"accounts":0,"availableAccounts":0,"unavailableAccounts":0,"lowestRemaining":null},"data":[],"cache":{"state":"miss"}}"#.utf8)
    )
    let staleState = try response(generatedAt: freshDate, cacheState: "stale")
    let staleTimestamp = try response(generatedAt: staleDate, cacheState: "miss")
    let missing = try response(generatedAt: freshDate, cacheState: nil)
    #expect(fresh.isFreshForAutomaticRouting)
    #expect(!staleState.isFreshForAutomaticRouting)
    #expect(!staleTimestamp.isFreshForAutomaticRouting)
    #expect(!missing.isFreshForAutomaticRouting)
}

@Test func codexQuotaAutomaticRoutingEnvelopeFailsClosed() throws {
    let generatedAt = ISO8601DateFormatter().string(from: Date())
    func envelope(_ suffix: String) -> Data {
        Data(
            (#"{"object":"list","generatedAt":"\#(generatedAt)","summary":{"accounts":0,"availableAccounts":0,"unavailableAccounts":0,"lowestRemaining":null},"data":[],"cache":{"state":"hit"\#(suffix)}}"#)
                .utf8
        )
    }

    let valid = envelope("")
    #expect(QuotaService.isSafeAutomaticRoutingEnvelope(data: valid))
    #expect(!QuotaService.isSafeAutomaticRoutingEnvelope(
        data: envelope(#","stale":true"#)
    ))
    #expect(!QuotaService.isSafeAutomaticRoutingEnvelope(
        data: envelope(#","available":false"#)
    ))
    #expect(!QuotaService.isSafeAutomaticRoutingEnvelope(
        data: envelope(#","partial":true"#)
    ))

    let rootFailures = [
        #"{"object":"list","generatedAt":"\#(generatedAt)","success":false,"summary":{"accounts":0,"availableAccounts":0,"unavailableAccounts":0,"lowestRemaining":null},"data":[],"cache":{"state":"hit"}}"#,
        #"{"object":"list","generatedAt":"\#(generatedAt)","error":{"code":"upstream_failed"},"summary":{"accounts":0,"availableAccounts":0,"unavailableAccounts":0,"lowestRemaining":null},"data":[],"cache":{"state":"hit"}}"#,
        #"{"object":"list","generatedAt":"\#(generatedAt)","summary":{"accounts":0,"availableAccounts":0,"unavailableAccounts":0,"lowestRemaining":null},"data":[],"cache":"hit"}"#,
        #"{"object":"list","generatedAt":"\#(generatedAt)","status":"partial","summary":{"accounts":0,"availableAccounts":0,"unavailableAccounts":0,"lowestRemaining":null},"data":[],"cache":{"state":"hit"}}"#
    ]
    for failure in rootFailures {
        #expect(!QuotaService.isSafeAutomaticRoutingEnvelope(data: Data(failure.utf8)))
    }

    let url = try #require(URL(string: "https://router.example.com/v1/quota"))
    let partialResponse = try #require(HTTPURLResponse(
        url: url,
        statusCode: 206,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    ))
    #expect(!QuotaService.isSafeAutomaticRoutingEnvelope(
        data: valid,
        response: partialResponse
    ))
}

private func automationAccount(
    rawID: String,
    remaining: Double,
    total: Double = 100,
    unlimited: Bool = false,
    status: String = "available",
    errorCode: String? = nil,
    additionalQuotas: [CodexQuotaWindow] = [],
    resetAt: String? = nil,
    usedOverride: Double? = nil
) -> CodexQuotaAccount {
    let fallbackResetAt = isoDate(offset: 60 * 60)
    let effectiveResetAt = resetAt ?? fallbackResetAt
    var normalizedAdditionalQuotas = additionalQuotas.map { quota in
        CodexQuotaWindow(
            key: quota.key,
            used: quota.used,
            total: quota.total,
            remaining: quota.remaining,
            resetAt: quota.resetAt ?? fallbackResetAt,
            unlimited: quota.unlimited
        )
    }
    if !normalizedAdditionalQuotas.contains(where: { $0.key.caseInsensitiveCompare("weekly") == .orderedSame }) {
        normalizedAdditionalQuotas.append(CodexQuotaWindow(
            key: "weekly",
            used: usedOverride ?? (total - remaining),
            total: total,
            remaining: remaining,
            resetAt: effectiveResetAt,
            unlimited: unlimited
        ))
    }
    return CodexQuotaAccount(
        id: NineRouterAutomationService.publicAccountID(for: rawID),
        provider: "codex",
        label: rawID,
        plan: "plus",
        limitReached: remaining <= 0,
        quotas: [CodexQuotaWindow(
            key: "session",
            used: usedOverride ?? (total - remaining),
            total: total,
            remaining: remaining,
            resetAt: effectiveResetAt,
            unlimited: unlimited
        )] + normalizedAdditionalQuotas,
        resetCredits: .init(availableCount: 0),
        status: status,
        errorCode: errorCode
    )
}

private func ownedAutomationState(_ rawID: String) -> NineRouterAutomationState {
    NineRouterAutomationState(
        autoDisabledConnectionIDs: [rawID],
        managementEndpointIdentity: "https://router.example.com",
        deactivationWindows: [
            rawID: [
                "session": isoDate(offset: -60 * 60),
                "weekly": isoDate(offset: -60 * 60)
            ]
        ]
    )
}

private func isoDate(offset: TimeInterval) -> String {
    ISO8601DateFormatter().string(from: Date().addingTimeInterval(offset))
}

private func usageJSON(
    sessionRemaining: Double,
    weeklyRemaining: Double,
    sessionResetOffset: TimeInterval = 60 * 60,
    weeklyResetOffset: TimeInterval = 7 * 24 * 60 * 60,
    limitReached: Bool = false
) -> String {
    let sessionResetAt = isoDate(offset: sessionResetOffset)
    let weeklyResetAt = isoDate(offset: weeklyResetOffset)
    return #"{"plan":"plus","limitReached":\#(limitReached),"quotas":{"session":{"used":\#(100 - sessionRemaining),"total":100,"remaining":\#(sessionRemaining),"resetAt":"\#(sessionResetAt)","unlimited":false},"weekly":{"used":\#(100 - weeklyRemaining),"total":100,"remaining":\#(weeklyRemaining),"resetAt":"\#(weeklyResetAt)","unlimited":false}}}"#
}

private final class AutomationStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStates: [NineRouterAutomationState] = []

    var states: [NineRouterAutomationState] {
        lock.withLock { recordedStates }
    }

    func record(_ state: NineRouterAutomationState) {
        lock.withLock { recordedStates.append(state) }
    }
}

private func requestJSON(_ request: URLRequest) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
}

private actor NineRouterMockTransport: NineRouterHTTPTransport {
    private var pendingResponses: [NineRouterHTTPResponse]
    private(set) var requests: [URLRequest] = []

    init(responses: [NineRouterHTTPResponse]) {
        pendingResponses = responses
    }

    func send(_ request: URLRequest) async throws -> NineRouterHTTPResponse {
        requests.append(request)
        guard !pendingResponses.isEmpty else {
            throw NineRouterMockError.noResponse
        }
        return pendingResponses.removeFirst()
    }
}

private actor NineRouterCancellationTransport: NineRouterHTTPTransport {
    private let rawID: String
    private(set) var requests: [URLRequest] = []

    init(rawID: String) {
        self.rawID = rawID
    }

    func send(_ request: URLRequest) async throws -> NineRouterHTTPResponse {
        requests.append(request)
        switch requests.count {
        case 1:
            return .login()
        case 2:
            return .json(
                #"{"connections":[{"id":"\#(rawID)","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1}}"#
            )
        default:
            throw URLError(.cancelled)
        }
    }
}

private actor NineRouterCancelledResponseTransport: NineRouterHTTPTransport {
    private let rawID: String
    private var putStarted = false
    private var putWaiters: [CheckedContinuation<Void, Never>] = []
    private var putRelease: CheckedContinuation<Void, Never>?
    private(set) var requests: [URLRequest] = []

    init(rawID: String) {
        self.rawID = rawID
    }

    func waitUntilPutStarts() async {
        guard !putStarted else { return }
        await withCheckedContinuation { continuation in
            putWaiters.append(continuation)
        }
    }

    func releasePut() {
        putRelease?.resume()
        putRelease = nil
    }

    func send(_ request: URLRequest) async throws -> NineRouterHTTPResponse {
        requests.append(request)
        switch requests.count {
        case 1:
            return .login()
        case 2:
            return .json(
                #"{"connections":[{"id":"\#(rawID)","provider":"codex","authType":"oauth","isActive":true}],"pagination":{"totalPages":1}}"#
            )
        case 3:
            putStarted = true
            let waiters = putWaiters
            putWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                putRelease = continuation
            }
            return NineRouterHTTPResponse(statusCode: 500)
        default:
            return .json(#"{"connection":{"id":"unknown","isActive":true}}"#)
        }
    }
}

private actor NineRouterBlockingLoginTransport: NineRouterHTTPTransport {
    private var loginIsBlocked = false
    private var loginStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var loginRelease: CheckedContinuation<Void, Never>?
    private(set) var requests: [URLRequest] = []
    private(set) var didOverlapWhileLoginBlocked = false

    func waitUntilLoginStarts() async {
        guard !loginIsBlocked else { return }
        await withCheckedContinuation { continuation in
            loginStartedWaiters.append(continuation)
        }
    }

    func releaseLogin() {
        loginRelease?.resume()
        loginRelease = nil
    }

    func send(_ request: URLRequest) async throws -> NineRouterHTTPResponse {
        requests.append(request)
        if request.httpMethod == "POST" {
            if loginIsBlocked {
                didOverlapWhileLoginBlocked = true
                return .login()
            }
            loginIsBlocked = true
            let waiters = loginStartedWaiters
            loginStartedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                loginRelease = continuation
            }
            loginIsBlocked = false
            return .login()
        }
        return .json(#"{"connections":[],"pagination":{"totalPages":1}}"#)
    }
}

private enum NineRouterMockError: Error {
    case noResponse
}

private extension NineRouterHTTPResponse {
    static func login(cookie: String = "test-token") -> NineRouterHTTPResponse {
        NineRouterHTTPResponse(
            statusCode: 200,
            headers: ["Set-Cookie": "auth_token=\(cookie); Path=/; HttpOnly"],
            body: Data(#"{"success":true,"mustChangePassword":false}"#.utf8)
        )
    }

    static func json(_ value: String, statusCode: Int = 200) -> NineRouterHTTPResponse {
        NineRouterHTTPResponse(statusCode: statusCode, body: Data(value.utf8))
    }
}
