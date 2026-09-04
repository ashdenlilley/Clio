# Clio third-party notices

The following source dependencies are statically linked into Clio and require
no runtime network access. Their revisions are also locked in
`Package.resolved`.

- **swift-markdown 0.8.0**, revision
  `3c6f9523da3a1ec2fd829673e472d95b8097a3b8`, Copyright (c) 2021 Apple Inc.
  and the Swift project authors. Licensed under Apache License 2.0 with the
  Swift Runtime Library Exception. The complete upstream text is bundled as
  `Swift-Markdown-LICENSE-Part-1.txt` and `Swift-Markdown-LICENSE-Part-2.txt`.
- **swift-cmark / cmark-gfm 0.8.0**, revision
  `924936d0427cb25a61169739a7660230bffa6ea6`, Copyright (c) 2014 John
  MacFarlane. BSD-2-Clause. Its complete `COPYING` file, including the MIT
  notices for Houdini, GitHub buffer/chunk code, utf8proc, and the other
  transitive notices shipped upstream, is bundled as `Swift-CMark-COPYING-Part-1.txt`
  and `Swift-CMark-COPYING-Part-2.txt`.

The two numbered parts for each dependency are consecutive portions of the
single upstream license file, split only to keep the repository patch history
reviewable. They must remain together in every release bundle.
