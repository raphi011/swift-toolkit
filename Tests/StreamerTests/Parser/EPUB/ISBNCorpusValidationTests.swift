//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

//
//  LOCAL VALIDATION TOOL — NOT FOR UPSTREAM.
//
//  Runs `metadata.isbns` over a real corpus of EPUBs in ~/ebooks through the
//  full public pipeline (AssetRetriever -> PublicationOpener) and reports:
//    - summary stats + ISBN-count distribution
//    - Flag A (false negative): OPF text contains "isbn" but isbns is empty
//    - Flag B (false positive): a returned value isn't a plausible ISBN
//
//  Skips when ~/ebooks is absent, so it's a no-op everywhere else. This file
//  lives on a scratch branch only and is never merged into the PR.
//

import Foundation
import ReadiumShared
@testable import ReadiumStreamer
import XCTest

final class ISBNCorpusValidationTests: XCTestCase {
    private let log = "[ISBN-VALIDATION]"

    /// Absolute host path: simulator unit tests run as host macOS processes and
    /// can read host paths by absolute path (but `homeDirectoryForCurrentUser`
    /// would resolve to the simulator's sandbox home). Scratch-branch only.
    private let corpusPath = "/Users/raphaelgruber/ebooks"

    func testValidateISBNsOverLocalEbooks() async throws {
        let ebooksURL = URL(fileURLWithPath: corpusPath, isDirectory: true)

        guard FileManager.default.fileExists(atPath: ebooksURL.path) else {
            throw XCTSkip("\(corpusPath) not found; skipping corpus validation")
        }

        let epubs = try FileManager.default
            .contentsOfDirectory(at: ebooksURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "epub" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        print("\(log) Scanning \(epubs.count) EPUB(s) in \(ebooksURL.path)")

        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        let opener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )

        var scanned = 0
        var openFailures: [(String, String)] = []
        var distribution: [Int: Int] = [:] // isbn count -> number of books
        var missedISBN: [String] = [] // Flag A: OPF says "isbn", we returned none
        var malformed: [(String, [String])] = [] // Flag B: implausible returned value

        for url in epubs {
            scanned += 1
            let name = url.lastPathComponent

            guard let fileURL = FileURL(url: url) else {
                openFailures.append((name, "invalid file URL"))
                continue
            }

            do {
                let asset = try await assetRetriever.retrieve(url: fileURL).get()

                // Read the raw OPF first, while the asset's container is ours.
                let opfText = await Self.rawOPFText(from: asset)

                let publication = try await opener
                    .open(asset: asset, allowUserInteraction: false)
                    .get()
                let isbns = publication.metadata.isbns

                distribution[isbns.count, default: 0] += 1

                if isbns.isEmpty, let opfText, opfText.range(of: "isbn", options: .caseInsensitive) != nil {
                    missedISBN.append(name)
                }

                let bad = isbns.filter { !Self.isPlausibleISBN($0) }
                if !bad.isEmpty {
                    malformed.append((name, bad))
                }
            } catch {
                openFailures.append((name, "\(error)"))
            }
        }

        // MARK: - Report

        let openedOK = distribution.values.reduce(0, +)
        let zero = distribution[0] ?? 0
        let one = distribution[1] ?? 0
        let two = distribution[2] ?? 0
        let threePlus = distribution.filter { $0.key >= 3 }.values.reduce(0, +)

        print("""

        \(log) ===== SUMMARY =====
        \(log) scanned:        \(scanned)
        \(log) opened OK:      \(openedOK)
        \(log) open failures:  \(openFailures.count)
        \(log) with >=1 ISBN:  \(openedOK - zero)
        \(log) ISBN-count distribution:
        \(log)   0 ISBNs:  \(zero)
        \(log)   1 ISBN:   \(one)
        \(log)   2 ISBNs:  \(two)
        \(log)   3+ ISBNs: \(threePlus)
        """)

        print("\n\(log) ----- Flag A: OPF mentions \"isbn\" but isbns is empty (\(missedISBN.count)) -----")
        for name in missedISBN {
            print("\(log)   MISSED: \(name)")
        }

        print("\n\(log) ----- Flag B: returned value not a plausible ISBN (\(malformed.count)) -----")
        for (name, values) in malformed {
            print("\(log)   MALFORMED \(values): \(name)")
        }

        if !openFailures.isEmpty {
            print("\n\(log) ----- Open failures (\(openFailures.count), not a parser bug) -----")
            for (name, reason) in openFailures {
                print("\(log)   FAILED \(name): \(reason)")
            }
        }
        print("\(log) ===== END =====\n")

        // This is a report, not a pass/fail gate — the flags need human review.
        XCTAssertGreaterThan(openedOK, 0, "No EPUBs could be opened — pipeline likely misconfigured")
    }

    /// Locates and reads the package OPF text from an EPUB asset's container,
    /// the same way `EPUBContainerParser` does. nil if anything is unreadable.
    private static func rawOPFText(from asset: Asset) async -> String? {
        guard case let .container(containerAsset) = asset else { return nil }
        let container = containerAsset.container
        guard
            let parser = try? await EPUBContainerParser(container: container),
            let href = try? parser.parseOPFHREF(),
            let data = try? await container.readData(at: href)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A plausible ISBN after the parser's cleaning: 13 digits, or 10 chars
    /// (9 digits + a final digit or `X`).
    private static func isPlausibleISBN(_ value: String) -> Bool {
        switch value.count {
        case 13:
            return value.allSatisfy(\.isNumber)
        case 10:
            let last = value.last!
            return value.dropLast().allSatisfy(\.isNumber) && (last.isNumber || last == "X" || last == "x")
        default:
            return false
        }
    }
}
