# Tebako layered application package format

The source of truth for fixed fields is
[`format/layered_package.json`](../format/layered_package.json). Run
`ruby scripts/generate_layered_format.rb` after changing it.

Version 1.0 uses little-endian integers and ends with the eight-byte magic
`TEBAKOL1`. The version is encoded in that magic; readers must reject unknown
magic values rather than guessing a compatible layout.

The package layout is:

1. Tebako application descriptor.
2. One or more DwarFS layer payloads.
3. Layer manifest.
4. Footer.

The footer contains a `uint64` manifest byte length followed by the magic.
The manifest starts with a `uint32` layer count. Each record contains a
`uint16` UTF-8 mount-point length, the mount-point bytes, a `uint64` payload
offset, and a `uint64` payload length.

Mount points are relative, non-empty paths. Empty components and the `.` and
`..` components are forbidden. Mount points must be unique. Payload ranges
must be non-empty, must end before the manifest, and must not overlap.

Version 1 does not carry embedded payload checksums. `tebako package verify`
therefore validates its complete structure, bounds, and mount rules and reports
computed SHA-256 identities for inspection; it cannot authenticate a version 1
payload against an embedded digest. A checksum-bearing format requires a new
magic/version and corresponding runtime reader support.

## One-file executable containers

A layered package is wrapped in a single-file envelope containing the package
bytes, a little-endian `uint64` package length, a 32-byte SHA-256 digest, and
the eight-byte `TEBAKOB1` magic.

Linux and Windows place that envelope after the native executable. macOS places
the same envelope in the `__TEBAKO,__app` section of a dedicated `__TEBAKO`
Mach-O segment. The section is created during a targeted final link so it is
part of the signed Mach-O rather than unstructured trailing data. The runtime
locates the section through the loaded Mach-O header, validates the envelope
digest, and then parses the layered package.

The macOS link reuses the already-built Ruby objects, static extensions, and
runtime libraries. It does not compile Ruby or regenerate the runtime
filesystem. The resulting executable supports signature replacement followed
by `codesign --verify --deep --strict`.

Hardened Runtime signing must use `docs/macos-entitlements.plist`. Ruby's YJIT
requires executable anonymous memory, and native gem `.bundle` files are
extracted with independent ad-hoc signatures. The signing profile therefore
allows unsigned executable memory and disables library validation. Both pure
Ruby and native-gem fixtures are exercised with that profile; credentialed
Developer ID signing and notarization belong in release CI.
