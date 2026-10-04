# Third-party notices

Clio bundles the Hack typeface, version 3.003, by Source Foundry Authors.
Hack is distributed under the SIL Open Font License, Version 1.1. The complete
license and upstream notice are included in `Fonts/LICENSE-Hack.md` and
`Fonts/README.md` inside the application bundle.

Clio incorporates `swift-markdown` by Apple and the Swift project at revision
`3c6f9523da3a1ec2fd829673e472d95b8097a3b8`. It is distributed under the
Apache License 2.0 with Runtime Library Exception. The complete upstream
license is available at
<https://github.com/swiftlang/swift-markdown/blob/3c6f9523da3a1ec2fd829673e472d95b8097a3b8/LICENSE.txt>.

Clio incorporates `swift-cmark` / cmark-gfm at revision
`924936d0427cb25a61169739a7660230bffa6ea6`. The primary implementation is
Copyright (c) 2014 John MacFarlane and is distributed under a BSD 2-Clause
license; its bundled derived components retain their respective permissive
notices. The complete upstream notices are available at
<https://github.com/swiftlang/swift-cmark/blob/924936d0427cb25a61169739a7660230bffa6ea6/COPYING>.

These Markdown packages are linked into the Clio executable. Clio does not
download executable dependencies at runtime.

The Windows build also links `Microsoft.WindowsAppSDK` 2.5.1 and
`Microsoft.Graphics.Win2D` 1.4.0 by Microsoft, both distributed under the MIT
License. Upstream licenses are available at
<https://github.com/microsoft/WindowsAppSDK/blob/main/LICENSE> and
<https://github.com/microsoft/Win2D/blob/master/LICENSE.txt>.

The Windows editor also links `Markdig` 1.4.0 by Alexandre Mutel, distributed
under the BSD 2-Clause License, for CommonMark emphasis and strikethrough
delimiter ranges. The upstream license is available at
<https://github.com/xoofx/markdig/blob/master/license.txt>.

The Windows search index links `Microsoft.Data.Sqlite` 10.0.12 by Microsoft
(MIT License) and `SQLitePCLRaw.bundle_e_sqlite3` 2.1.12 by Eric Sink (Apache
License 2.0), which bundles the SQLite library. SQLite is in the public domain.
Upstream licenses are available at
<https://github.com/dotnet/efcore/blob/main/LICENSE.txt> and
<https://github.com/ericsink/SQLitePCL.raw/blob/main/LICENSE.txt>.
