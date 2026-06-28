//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

private let mediaOverlayKey = "mediaOverlay"
private let isbnKey = "isbn"

public extension Metadata {
    /// Media overlay CSS class names for this publication.
    var mediaOverlay: EPUBMediaOverlay? {
        try? otherMetadata[mediaOverlayKey]?.decode()
    }

    /// ISBNs declared by the publication, as found in the OPF.
    ///
    /// The package's primary `identifier` is usually a UUID, so an ISBN — when
    /// present — is typically a *secondary* `dc:identifier` tagged via an
    /// `opf:scheme` attribute (EPUB 2), an `identifier-type` ONIX code (EPUB 3),
    /// or expressed as a `urn:isbn:` URN. A publication may declare more than one
    /// (e.g. the ISBN-10 and ISBN-13 of the same book, or distinct ISBNs per
    /// format). Values are returned as declared, with only the scheme prefix and
    /// separators removed — no normalization. Empty when the publication carries
    /// no recognizable ISBN.
    var isbns: [String] {
        guard case let .array(values)? = otherMetadata[isbnKey] else { return [] }
        return values.compactMap {
            guard case let .string(value) = $0 else { return nil }
            return value
        }
    }
}
