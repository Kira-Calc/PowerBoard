# Third-party notices

This project includes or derives from the following third-party works.

## swift-argument-parser

- Source: https://github.com/apple/swift-argument-parser
- License: Apache License 2.0
- Use: Swift Package Manager dependency of the `powerboard` command-line tool. Not vendored.
- Full license text: https://github.com/apple/swift-argument-parser/blob/main/LICENSE.txt

## GRDB.swift

- Source: https://github.com/groue/GRDB.swift (resolved 7.11.1)
- License: MIT
- Use: Swift Package Manager dependency of ElectricityCore, for the SQLite database. Not vendored.

```
Copyright (C) 2015-2025 Gwendal Roué

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## claude-carbon

- Source: https://github.com/gwittebolle/claude-carbon (commit d7313ff88c88f69f4a152ee74dd39dd3636f9e9a)
- License: MIT
- Use: emission factors and methodology notes, converted to energy factors in `Packages/ElectricityCore/Sources/ElectricityCore/Resources/energy-factors.json`. No code is copied.

```
MIT License

Copyright (c) 2026 Gaetan Wittebolle

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## ccusage

- Source: https://github.com/ryoppippi/ccusage
- License: MIT
- Use: reference for how Claude Code logs are located and deduplicated. No code is copied.
