import Foundation
import web3

enum QuorumWave {
    enum TrustTier {
        case verified
        case unverified
    }

    enum Resolution {
        case data(bytes: Data, resolver: EthereumAddress, urls: [URL], trust: TrustTier)
        case notFound(reason: ENSNotFoundReason, urls: [URL], trust: TrustTier)
        case conflict
        case allErrored
    }

    struct Outcome {
        let resolution: Resolution
        let byData: [Data: [URL]]
        let byNegative: [ENSNotFoundReason: [URL]]
        let queried: [URL]
        let mUsed: Int
    }

    typealias LegRunner = @Sendable (URL, Data, Data, String, TimeInterval, Bool) async -> QuorumLeg.Outcome

    /// K parallel UR.resolve() legs at `blockHash`. Each resolvedData value
    /// and each negative reason bucket separately — NO_RESOLVER and
    /// NO_CONTENTHASH are distinct states, so a transient CCIP failure
    /// cannot combine with a real registration miss to forge a verified
    /// not-found. Returns as soon as any bucket reaches M and cancels the
    /// remaining legs; late-arriving cancelled legs are not merged, which
    /// is fine for verdict correctness but means `queried.count - agreed`
    /// isn't a reliable "silent provider" count for conflict diagnostics.
    static func run(
        providers: [URL],
        dnsEncodedName: Data,
        callData: Data,
        blockHash: String,
        timeout: TimeInterval,
        m: Int,
        enableCcipRead: Bool = false,
        legRunner: @escaping LegRunner = defaultLegRunner
    ) async -> Outcome {
        var legs: [URL: QuorumLeg.Outcome] = [:]
        var byData: [Data: [URL]] = [:]
        var byNegative: [ENSNotFoundReason: [URL]] = [:]
        var early: Resolution?

        await withTaskGroup(of: QuorumLeg.Outcome.self) { group in
            for url in providers {
                group.addTask {
                    await legRunner(url, dnsEncodedName, callData, blockHash, timeout, enableCcipRead)
                }
            }

            for await leg in group {
                legs[leg.url] = leg
                switch leg.kind {
                case .data(let bytes, let resolver):
                    byData[bytes, default: []].append(leg.url)
                    if let urls = byData[bytes], urls.count >= m {
                        early = .data(bytes: bytes, resolver: resolver, urls: urls, trust: .verified)
                    }
                case .notFound(let reason):
                    byNegative[reason, default: []].append(leg.url)
                    if let urls = byNegative[reason], urls.count >= m {
                        early = .notFound(reason: reason, urls: urls, trust: .verified)
                    }
                case .error:
                    break
                }
                if early != nil {
                    group.cancelAll()
                    break
                }
            }
        }

        let resolution = early ?? classifyNoAgreement(legs: legs)
        return Outcome(
            resolution: resolution,
            byData: byData,
            byNegative: byNegative,
            queried: providers,
            mUsed: m
        )
    }

    private static func classifyNoAgreement(legs: [URL: QuorumLeg.Outcome]) -> Resolution {
        var dataLegs: [QuorumLeg.Outcome] = []
        var notFoundLegs: [QuorumLeg.Outcome] = []
        for leg in legs.values {
            switch leg.kind {
            case .data: dataLegs.append(leg)
            case .notFound: notFoundLegs.append(leg)
            case .error: break
            }
        }
        let total = dataLegs.count + notFoundLegs.count
        if total == 0 {
            return .allErrored
        }
        if total == 1 {
            if let leg = dataLegs.first, case .data(let bytes, let resolver) = leg.kind {
                return .data(bytes: bytes, resolver: resolver, urls: [leg.url], trust: .unverified)
            }
            if let leg = notFoundLegs.first, case .notFound(let reason) = leg.kind {
                return .notFound(reason: reason, urls: [leg.url], trust: .unverified)
            }
        }
        return .conflict
    }

    nonisolated static let defaultLegRunner: LegRunner = { url, name, data, blockHash, timeout, ccip in
        await QuorumLeg.run(
            url: url,
            dnsEncodedName: name,
            callData: data,
            blockHash: blockHash,
            timeout: timeout,
            enableCcipRead: ccip
        )
    }
}
