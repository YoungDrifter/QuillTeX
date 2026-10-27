#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/checks
swiftc() { command swiftc -module-cache-path "$PWD/build/checks/ModuleCache" "$@"; }
swiftc QuillTeX/Project/project_index.swift Tests/project_index_tests.swift -o build/checks/ProjectIndexTests
build/checks/ProjectIndexTests
swiftc -parse-as-library QuillTeX/Project/project_index.swift QuillTeX/Project/document_library.swift QuillTeX/Project/project_store.swift QuillTeX/Project/workspace_session.swift QuillTeX/Editor/source_editor.swift QuillTeX/Editor/latex_highlighter.swift QuillTeX/Editor/latex_completion.swift QuillTeX/Build/build_strategy.swift QuillTeX/Build/build_settings.swift QuillTeX/Build/build_diagnostics.swift QuillTeX/Build/build_controller.swift QuillTeX/Build/sync_tex_service.swift QuillTeX/Preview/pdf_highlight.swift QuillTeX/App/Chrome.swift QuillTeX/App/chrome_interaction.swift QuillTeX/App/surface_styles.swift QuillTeX/App/plugin_manager.swift QuillTeX/App/recent_projects_view.swift QuillTeX/App/settings_components.swift QuillTeX/Build/build_controls.swift Tests/editor_behavior_tests.swift -o build/checks/EditorBehaviorTests
build/checks/EditorBehaviorTests

swiftc -parse-as-library QuillTeX/Project/document_library.swift Tests/document_library_tests.swift -o build/checks/DocumentLibraryTests
build/checks/DocumentLibraryTests

swiftc -parse-as-library QuillTeX/Build/build_strategy.swift QuillTeX/Build/build_settings.swift QuillTeX/Build/build_diagnostics.swift QuillTeX/Build/build_controller.swift QuillTeX/Build/sync_tex_service.swift QuillTeX/Preview/pdf_highlight.swift Tests/build_pipeline_tests.swift -o build/checks/BuildPipelineTests
build/checks/BuildPipelineTests

swiftc -parse-as-library QuillTeX/Build/sync_tex_service.swift Tests/sync_tex_service_tests.swift -o build/checks/SyncTeXServiceTests
build/checks/SyncTeXServiceTests

swiftc -parse-as-library QuillTeX/App/workspace_split.swift Tests/workspace_layout_tests.swift -o build/checks/WorkspaceLayoutTests
build/checks/WorkspaceLayoutTests

previewSources=(QuillTeX/**/*.swift)
previewSources=(${previewSources:#QuillTeX/App/*})
previewSources+=(QuillTeX/App/Chrome.swift QuillTeX/App/chrome_interaction.swift QuillTeX/App/surface_styles.swift QuillTeX/App/plugin_manager.swift QuillTeX/App/recent_projects_view.swift QuillTeX/App/settings_components.swift)
swiftc -parse-as-library $previewSources Tests/pdf_preview_tests.swift -o build/checks/PDFPreviewTests
build/checks/PDFPreviewTests

swiftc -parse-as-library $previewSources Tests/external_file_changes_tests.swift -o build/checks/ExternalFileChangesTests
build/checks/ExternalFileChangesTests

swiftc -parse-as-library $previewSources Tests/sidebar_file_operations_tests.swift -o build/checks/SidebarFileOperationsTests
build/checks/SidebarFileOperationsTests

swiftc -parse-as-library $previewSources Tests/subfile_insertion_tests.swift -o build/checks/SubfileInsertionTests
build/checks/SubfileInsertionTests

swiftc -parse-as-library $previewSources Tests/workspace_session_tests.swift -o build/checks/WorkspaceSessionTests
build/checks/WorkspaceSessionTests

swiftc -parse-as-library $previewSources Tests/chrome_animation_tests.swift -o build/checks/ChromeAnimationTests
build/checks/ChromeAnimationTests

swiftc -parse-as-library QuillTeX/App/plugin_manager.swift Tests/plugin_manager_tests.swift -o build/checks/PluginManagerTests
build/checks/PluginManagerTests
