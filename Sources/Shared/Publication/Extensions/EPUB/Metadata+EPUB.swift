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

    /// ISBN of the publication, normalized to ISBN-13.
    ///
    /// The package's primary `identifier` is usually a UUID, so the ISBN — when
    /// present — is typically a *secondary* `dc:identifier` tagged via an
    /// `opf:scheme` attribute (EPUB 2), an `identifier-type` ONIX code (EPUB 3),
    /// or expressed as a `urn:isbn:` URN. `nil` when the publication carries no
    /// recognizable ISBN.
    var isbn: String? {
        guard case let .string(value)? = otherMetadata[isbnKey] else { return nil }
        return value
    }
}
