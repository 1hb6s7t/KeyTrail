# Third-party notices and publication boundary

The root Apache-2.0 license applies to KeyTrail-owned source, except materials
identified under their own terms. It does not relicense dependencies, SDKs or models.
This source distribution does not include prebuilt applications or vendored crates.

## BongoCat source attribution

[BongoCat](https://github.com/ayangweb/BongoCat), Copyright 2025-present ayangweb,
uses [Apache License 2.0](https://github.com/ayangweb/BongoCat/blob/b82b4750b776df1408db07d5858d37db1594c3f3/LICENSE).
The ABI declarations in `Sources/KeyTrailPet/CubismModel.swift` follow its bindings
at revision `b82b4750b776df1408db07d5858d37db1594c3f3` and were adapted to Swift
for KeyTrail. The provenance comment and attribution are retained in source/NOTICE. A copy of
the upstream license is in [BongoCat-LICENSE.txt](docs/licenses/BongoCat-LICENSE.txt).
This does not extend Apache-2.0 to Live2D headers/runtime or third-party models.

The [upstream model catalog](https://github.com/ayangweb/Awesome-BongoCat) credits
the classic model to MMmmmoko. Attribution and a repository license alone do not
establish all model/character redistribution rights. Models, textures, keyboard
overlays, audio, SDKs and screenshots containing those assets are excluded from
this initial source snapshot. See [optional integration](docs/bongo-cat-assets.md).

## Live2D — optional external dependency

The Cubism Core uses the [Live2D Proprietary Software License](https://www.live2d.com/eula/live2d-proprietary-software-license-agreement_en.html).
The Native Framework uses its [separate license](https://github.com/Live2D/CubismNativeFramework/blob/develop/LICENSE.md).
KeyTrail does not ship either component in this source snapshot. Developers obtain
an appropriate SDK directly and review the [publication license](https://www.live2d.com/en/sdk/license/)
for their intended product. Source availability, a local build or a file listed as
redistributable is not blanket permission for every binary release.

## Rust dependencies and SQLite

Exact dependency versions are pinned in `rust/Cargo.lock`; their own package
licenses apply. Direct dependencies include serde/serde_json, rusqlite,
aes-gcm, base64, unicode-segmentation, windows and windows-sys. The source repository
references these packages rather than copying their source or binary libraries.

Do not label the complete dependency graph Apache-only. For example, rusqlite and
libsqlite3-sys use MIT; subtle uses BSD-3-Clause; unicode-ident includes Unicode-3.0
alongside its MIT/Apache alternatives. Bundled SQLite is covered by SQLite's
[public-domain statement](https://www.sqlite.org/copyright.html), distinct from the
wrapper's license. Before distributing binaries or vendoring packages, collect
all exact applicable target-specific license texts and notices, including build
and optional dependencies actually distributed.

## Project artwork and platform resources

`Sources/KeyTrailApp/Resources/journal-keycaps.png` is project-generated transparent
keycap artwork created for the selected KeyTrail interface. Its generation provenance
was recorded during design work; it is separate from BongoCat assets and is included
with the KeyTrail-owned project materials. Standard native UI icons refer to system
SF Symbols; no Apple symbol library, framework or SDK is vendored here.
