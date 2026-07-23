# SwiftTerm vendor provenance

This record makes the `Sources/SwiftTerm` lineage reproducible without treating
a moving branch as an anchor or claiming that the current vendored tree is
byte-identical to the fork anchor.

## Immutable anchors

| Role | Repository | Object |
|---|---|---|
| Fork base | `migueldeicaza/SwiftTerm` | commit `31553fe7fc192835ebb13c12d31f6b4c4d565dd6` |
| Fork anchor | `soyeht/iSoyehtTerm` | annotated tag `vendor-anchor-2026-07-23` |
| Annotated tag object | `soyeht/iSoyehtTerm` | `89cf98f003561e808c660f241d0f09a3a2257c51` |
| Tag target | `soyeht/iSoyehtTerm` | commit `a6351d8aee88a87f7e87ed276a6369c0d2211064` |
| Fork `Sources/SwiftTerm` tree | `soyeht/iSoyehtTerm` | `c351e4e1a84eedfe21967841da0241b60ae4d630` |
| Mirrored tree | `soyeht/soyeht-ios` | commit `4c3a1028921576fad7893a67778a02a0368fedf9`, tree `c351e4e1a84eedfe21967841da0241b60ae4d630` |
| Audited vendor snapshot | `soyeht/soyeht-ios` | commit `b37b9f41137a0e739b9a3aa22dd51d0378910b2e` |
| Audited vendor tree | `soyeht/soyeht-ios` | `73b054b10ff993def820a885da791d12a8892265` |

The fork anchor and the mirrored commit have the same `Sources/SwiftTerm` tree.
The current vendor snapshot does not: it is the mirrored tree plus the 13
path-scoped patches enumerated in
[`swiftterm-vendored-delta.tsv`](swiftterm-vendored-delta.tsv). The stable
aggregate patch-id from the mirrored tree to the audited vendor tree is
`73f4730033a1bc19b41ed92040aa10302cbafcbb`.

## Complete patch inventories

[`swiftterm-fork-series.tsv`](swiftterm-fork-series.tsv) records all 31
non-merge commits from the immutable upstream base to the fork anchor. It
contains each full-commit stable patch-id. Six of those commits touch
`Sources/SwiftTerm`; for each, the table also records the path-scoped stable
patch-id and the commit in `soyeht-ios` whose path-scoped patch-id is identical.
The other 25 commits remain enumerated instead of being silently discarded;
they affect the fork application but not the vendored library subtree.

[`swiftterm-vendored-delta.tsv`](swiftterm-vendored-delta.tsv) records every
commit after the byte-identical mirrored tree and through the audited
`b37b9f41` vendor snapshot that changes `Sources/SwiftTerm`. Its 13 stable
path-scoped patch-ids reconstruct the audited vendor tree in history order.

## Reproduction

From a full clone of `soyeht/soyeht-ios`:

```sh
scripts/verify-swiftterm-vendor-provenance.sh
```

The verifier:

1. clones the public fork and resolves the annotated tag object and target;
2. verifies the immutable base-to-anchor 31-commit sequence and every recorded
   full/path-scoped patch-id;
3. verifies the six fork-to-mirror path patch-id correspondences;
4. proves that the fork anchor and mirrored `Sources/SwiftTerm` trees are
   byte-identical;
5. verifies all 13 post-anchor vendor patches, the final vendor tree and the
   aggregate patch-id; and
6. refuses a checkout whose current vendored tree differs from the audited
   snapshot.

The dedicated GitHub Actions workflow runs the same verifier with complete Git
history.

## Boundary

This is a source-lineage record only. It does not re-vendor files, discard
patches, select an adapter architecture, open a provider, or import Product A.
The fork tag anchors the fork state; it is not a claim that the later vendored
tree is identical to that state.
