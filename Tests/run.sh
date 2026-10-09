#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/checks
swiftc QuillTeX/Project/ProjectIndex.swift Tests/ProjectIndexTests.swift -o build/checks/ProjectIndexTests
build/checks/ProjectIndexTests
swiftc -parse-as-library QuillTeX/Project/ProjectIndex.swift QuillTeX/Project/DocumentLibrary.swift QuillTeX/Project/ProjectStore.swift QuillTeX/Editor/SourceEditor.swift QuillTeX/Editor/LaTeXHighlighter.swift QuillTeX/Editor/LaTeXCompletion.swift QuillTeX/Editor/CompletionPanel.swift QuillTeX/Build/BuildStrategy.swift QuillTeX/Build/BuildSettings.swift QuillTeX/Build/BuildDiagnostics.swift QuillTeX/Build/BuildController.swift QuillTeX/Build/SyncTeXService.swift QuillTeX/Preview/PDFHighlight.swift Tests/EditorBehaviorTests.swift -o build/checks/EditorBehaviorTests
build/checks/EditorBehaviorTests

swiftc -parse-as-library QuillTeX/Project/DocumentLibrary.swift Tests/DocumentLibraryTests.swift -o build/checks/DocumentLibraryTests
build/checks/DocumentLibraryTests

swiftc -parse-as-library QuillTeX/Build/BuildStrategy.swift QuillTeX/Build/BuildSettings.swift QuillTeX/Build/BuildDiagnostics.swift QuillTeX/Build/BuildController.swift QuillTeX/Build/SyncTeXService.swift QuillTeX/Preview/PDFHighlight.swift Tests/BuildPipelineTests.swift -o build/checks/BuildPipelineTests
build/checks/BuildPipelineTests

swiftc -parse-as-library QuillTeX/App/WorkspaceSplit.swift Tests/WorkspaceLayoutTests.swift -o build/checks/WorkspaceLayoutTests
build/checks/WorkspaceLayoutTests

previewSources=(QuillTeX/**/*.swift)
previewSources=(${previewSources:#QuillTeX/App/*})
previewSources+=(QuillTeX/App/Chrome.swift)
swiftc -parse-as-library $previewSources Tests/PDFPreviewTests.swift -o build/checks/PDFPreviewTests
build/checks/PDFPreviewTests

swiftc -parse-as-library QuillTeX/App/PluginManager.swift Tests/PluginManagerTests.swift -o build/checks/PluginManagerTests
build/checks/PluginManagerTests
