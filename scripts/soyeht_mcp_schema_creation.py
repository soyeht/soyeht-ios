from soyeht_mcp_foundation import *

TOOLS_CREATION = [
    {
        "name": "open_panes",
        "description": "Open new Soyeht panes/tabs in the caller/source workspace when available, otherwise the active workspace in the resolved window, using existing directories. Prefer open_agent_pane when the user names a coding harness/CLI; this compatibility tool still honors the full harness catalog and default launch profiles. A harness is the program around a model (for example Codex, Claude Code, or OpenCode); the named Soyeht pane is the agent users communicate with. Agent panes do not steal focus by default. Use Soyeht for user requests that mention a new shell, terminal, tab, pane, or opening something in this workspace instead of using Terminal.app or osascript. If prompt is provided for an AI agent, it is delivered as a Soyeht agent message with sender/reply metadata by default; set promptMode=raw only for literal terminal input.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "panes": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "name": {"type": "string"},
                            "path": {"type": "string"},
                            "agent": {"type": "string"},
                            "command": {"type": "string"},
                            "prompt": {"type": "string"},
                            "promptMode": PROMPT_MODE_PROPERTY,
                            "promptDelayMs": PROMPT_DELAY_MS_PROPERTY,
                        },
                        "required": ["name", "path"],
                    },
                },
                "agent": {"type": "string", "default": "codex"},
                "command": {"type": "string"},
                "prompt": {"type": "string"},
                "promptMode": PROMPT_MODE_PROPERTY,
                "promptDelayMs": PROMPT_DELAY_MS_PROPERTY,
                "activate": {
                    "type": "boolean",
                    "description": "Focus the newly created panes. Defaults to false for agent panes and true for shell-only panes.",
                },
                "fromConversationID": FROM_CONVERSATION_ID_PROPERTY,
                "fromHandle": FROM_HANDLE_PROPERTY,
                "nameStyle": {"type": "string", "enum": NAME_STYLE_CHOICES},
                "paneNameStyle": {
                    "type": "string",
                    "enum": NAME_STYLE_CHOICES,
                    "description": "Pane/tab names default to short hyphen names, e.g. 'Bug Login' becomes @bug-login. Use verbatim when the user asks for an exact name.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_BATCH_CREATE_TIMEOUT},
            },
            "required": ["panes"],
        },
    },
    {
        "name": "open_shell",
        "description": "Open a new Soyeht shell pane/tab in the caller/source workspace when available, otherwise the active workspace in the resolved window. Use this when the user asks for a new shell, terminal, tab, or pane in the current Soyeht workspace, optionally running a command such as vim, npm test, git status, or an agent command. Do not use Terminal.app or osascript for this intent. If prompt is provided for an AI agent, it is delivered as a Soyeht agent message with sender/reply metadata by default; set promptMode=raw only when simulating a user typing literal input.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "default": ".",
                    "description": "Working directory for the new shell pane.",
                },
                "cwd": {
                    "type": "string",
                    "description": "Alias for path.",
                },
                "name": {
                    "type": "string",
                    "description": "Pane/tab name. If omitted for a shell pane, Soyeht assigns a random unused friendly name.",
                },
                "paneName": {"type": "string"},
                "command": {
                    "type": "string",
                    "description": "Optional shell command to run after opening the pane. Leave absent for a plain interactive shell.",
                },
                "agent": {"type": "string", "default": "shell"},
                "prompt": {"type": "string"},
                "promptMode": PROMPT_MODE_PROPERTY,
                "promptDelayMs": PROMPT_DELAY_MS_PROPERTY,
                "activate": {
                    "type": "boolean",
                    "description": "Focus the newly created pane. Defaults to false for an agent and true for a plain shell.",
                },
                "fromConversationID": FROM_CONVERSATION_ID_PROPERTY,
                "fromHandle": FROM_HANDLE_PROPERTY,
                "nameStyle": {"type": "string", "enum": NAME_STYLE_CHOICES},
                "paneNameStyle": {
                    "type": "string",
                    "enum": NAME_STYLE_CHOICES,
                    "description": "Pane/tab names default to short hyphen names.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {
                    "type": "number",
                    "default": DEFAULT_AGENT_CREATE_TIMEOUT,
                    "description": "Maximum seconds to wait for process startup and the app-observed initial-prompt acknowledgement.",
                },
            },
        },
    },
    {
        "name": "open_agent_pane",
        "description": (
            "Open exactly one requested coding-agent CLI in a new Soyeht pane. Use this instead of "
            "open_shell/open_panes whenever the user names Codex, Claude Code, OpenCode, Qwen, "
            "Antigravity, Pi, Droid, Kilo, Cursor, Copilot, Grok, Kimi, Devin, or Qoder. agentID is "
            "fail-closed: an unknown ID or a profile belonging to another agent is rejected, never "
            "silently replaced. Codex defaults to profile codex-yolo (codex --yolo) and OpenCode "
            "defaults to opencode-auto (opencode --auto); pass profile=base to suppress profile flags. "
            "The response returns launchContract.command and expectedArgv for audit, but always marks "
            "argvVerification as required/unverified. Acceptance requires an E2E observation of the live "
            "child process argv in Soyeht Dev; declaredAgent, pane title, and request metadata are not proof. "
            "An explicit name/paneName is preserved verbatim unless a name style is explicitly requested."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "agentID": {
                    "type": "string",
                    "enum": list(AGENT_CATALOG),
                    "description": "Exact stable agent ID. The tool rejects unknown IDs instead of choosing a fallback agent.",
                },
                "cwd": {
                    "type": "string",
                    "default": ".",
                    "description": "Existing working directory in which the exact agent process must launch.",
                },
                "path": {"type": "string", "description": "Legacy alias for cwd."},
                "workspace": {
                    "type": "string",
                    "description": "Stable destination workspace UUID; alias for workspaceID.",
                },
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "model": {
                    "type": "string",
                    "description": "Requested model, encoded as the catalogued --model argument and verified through real argv E2E.",
                },
                "args": {
                    "type": "array",
                    "items": {"type": "string"},
                    "default": [],
                    "description": "Additional literal argv entries appended after profile and model arguments.",
                },
                "profile": {
                    "type": "string",
                    "enum": ["base", *LAUNCH_PROFILES],
                    "description": "Named launch profile. Omit for per-agent defaults; base launches only the executable plus model/args.",
                },
                "name": {"type": "string", "description": "Optional pane name."},
                "paneName": {"type": "string", "description": "Alias for name."},
                "prompt": {"type": "string", "description": "Optional initial agent message after startup."},
                "promptMode": PROMPT_MODE_PROPERTY,
                "promptDelayMs": PROMPT_DELAY_MS_PROPERTY,
                "activate": {
                    "type": "boolean",
                    "default": False,
                    "description": "Focus the newly created pane. Defaults to false so an agent opening a collaborator cannot steal the user's typing focus.",
                },
                "fromConversationID": FROM_CONVERSATION_ID_PROPERTY,
                "fromHandle": FROM_HANDLE_PROPERTY,
                "nameStyle": {"type": "string", "enum": NAME_STYLE_CHOICES},
                "paneNameStyle": {"type": "string", "enum": NAME_STYLE_CHOICES},
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {
                    "type": "number",
                    "default": DEFAULT_AGENT_CREATE_TIMEOUT,
                    "description": "Maximum seconds to wait for process startup and the app-observed initial-prompt acknowledgement.",
                },
            },
            "required": ["agentID"],
        },
    },
    {
        "name": "open_file",
        "description": "Open a file in vim or another editor inside a new Soyeht shell pane/tab. Use this when the user asks to open a random file, any file, or a specific file in vim/nvim/nano/code in a new shell, terminal, tab, or pane. If file is omitted, the tool picks a random matching file from directory. Do not use Terminal.app or osascript for this intent.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "file": {
                    "type": "string",
                    "description": "Specific file to open. If omitted, a random matching file is selected from directory/path.",
                },
                "directory": {
                    "type": "string",
                    "default": ".",
                    "description": "Directory to search when file is omitted.",
                },
                "path": {
                    "type": "string",
                    "description": "Alias for directory.",
                },
                "root": {
                    "type": "string",
                    "description": "Native editor root folder. Used only when mode=native/editor.",
                },
                "editor": {
                    "type": "string",
                    "default": "vim",
                    "description": "Editor command to run when mode=shell. Defaults to vim.",
                },
                "mode": {
                    "type": "string",
                    "enum": ["shell", "native", "editor"],
                    "default": "shell",
                    "description": "shell preserves the legacy behavior and opens vim in a terminal pane. native/editor opens Soyeht's native editor pane.",
                },
                "line": {
                    "type": "integer",
                    "description": "Optional 1-based line number for vim/nvim/vi.",
                },
                "column": {
                    "type": "integer",
                    "description": "Optional 1-based column for mode=native/editor.",
                },
                "patterns": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Glob patterns for random file selection.",
                    "default": DEFAULT_FILE_PATTERNS,
                },
                "maxDepth": {
                    "type": "integer",
                    "default": 4,
                    "description": "Maximum directory depth for random file search.",
                },
                "name": {
                    "type": "string",
                    "description": "Pane/tab name. Defaults to editor-file.",
                },
                "nameStyle": {"type": "string", "enum": NAME_STYLE_CHOICES},
                "paneNameStyle": {
                    "type": "string",
                    "enum": NAME_STYLE_CHOICES,
                    "description": "Pane/tab names default to short hyphen names.",
                },
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_REQUEST_TIMEOUT},
            },
        },
    },
    {
        "name": "open_editor",
        "description": "Open or focus a native Soyeht editor pane for a file. Use this when the user says 'open this file in the editor', 'show README in the editor', or equivalent. This does not run vim or any shell command.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "file": {"type": "string", "description": "File to open in the native editor."},
                "directory": {"type": "string", "default": ".", "description": "Directory used for file search when file is omitted."},
                "path": {"type": "string", "description": "Alias for directory."},
                "root": {"type": "string", "description": "Root folder for the file explorer sidebar."},
                "line": {"type": "integer", "description": "Optional 1-based line number."},
                "column": {"type": "integer", "description": "Optional 1-based column number."},
                "patterns": {"type": "array", "items": {"type": "string"}, "default": DEFAULT_FILE_PATTERNS},
                "maxDepth": {"type": "integer", "default": 4},
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_REQUEST_TIMEOUT},
            },
        },
    },
    {
        "name": "open_explorer",
        "description": "Open or focus a native Soyeht file explorer/editor pane for a folder. Use this when the user says 'open this folder in the explorer' or equivalent.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "default": ".", "description": "Folder to open."},
                "root": {"type": "string", "description": "Alias for path."},
                "directory": {"type": "string", "description": "Alias for path."},
                "cwd": {"type": "string", "description": "Alias for path."},
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_REQUEST_TIMEOUT},
            },
        },
    },
    {
        "name": "open_git",
        "description": "Open or focus a native Soyeht Git pane for a repository. Use this when the user says 'open the changes', 'show git for this branch', 'open this repo in Git', or equivalent. Git commands only run when the user clicks buttons inside the pane.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "repo": {"type": "string", "default": ".", "description": "Repository folder or any folder inside the repository."},
                "path": {"type": "string", "description": "Alias for repo."},
                "root": {"type": "string", "description": "Alias for repo."},
                "selectedFile": {"type": "string", "description": "Optional file to select in the Git pane."},
                "file": {"type": "string", "description": "Alias for selectedFile."},
                "branch": {"type": "string"},
                "compareBase": {"type": "string"},
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_REQUEST_TIMEOUT},
            },
        },
    },
    {
        "name": "open_diff",
        "description": "Open or focus a native Soyeht Git pane with a file diff selected. Use this when the user asks to open/review the diff for a file or changes in a repo.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "file": {"type": "string", "description": "File whose diff should be selected."},
                "selectedFile": {"type": "string", "description": "Alias for file."},
                "repo": {"type": "string", "description": "Repository folder when no file is provided."},
                "path": {"type": "string", "description": "Alias for repo when no file is provided."},
                "root": {"type": "string", "description": "Alias for repo."},
                "branch": {"type": "string"},
                "compareBase": {"type": "string"},
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_REQUEST_TIMEOUT},
            },
        },
    },
    {
        "name": "open_web",
        "description": (
            "Open or focus a native Soyeht web pane (browser) for a URL. Use this when the user asks to open a website or web app in a pane. "
            "Only http/https URLs are accepted; the app validates fail-closed. "
            "By default, opening the same URL focuses the existing web pane for it and navigates it back to that URL (tab-like reuse). "
            "Set newPane=true to always create a separate pane. "
            "Snake_case aliases workspace_id, window_id and new_pane are also accepted."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "url": {"type": "string", "description": "http(s) URL to open. A bare host (e.g. example.com) is accepted and https:// is assumed."},
                "newPane": {"type": "boolean", "default": False, "description": "When true, always create a new web pane instead of reusing the existing pane for this URL."},
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_REQUEST_TIMEOUT},
            },
            "required": ["url"],
        },
    },
    {
        "name": "install_app",
        "description": (
            "Install a local Soyeht app bundle (a directory with a manifest.json) so it can be opened in app panes. "
            "Returns the install record, including the installID that open_app needs and the bundle fingerprint. "
            "The app validates the bundle fail-closed (manifest shape, symlink confinement, no capabilities in phase 2a)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Path to the app bundle directory (must contain manifest.json)."},
                "root": {"type": "string", "description": "Alias for path."},
                "directory": {"type": "string", "description": "Alias for path."},
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_REQUEST_TIMEOUT},
            },
            "required": ["path"],
        },
    },
    {
        "name": "open_app",
        "description": (
            "Open or focus the app pane for an installed Soyeht app. Use the installID returned by install_app. "
            "Snake_case aliases install_id, workspace_id and window_id are also accepted."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "installID": {"type": "string", "description": "Installer-issued installation ID, as returned by install_app."},
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_REQUEST_TIMEOUT},
            },
            "required": ["installID"],
        },
    },
    {
        "name": "create_worktree_panes",
        "description": (
            "Create one or more git worktrees and open each as a new Soyeht tab/pane. "
            "All panes run the same single agent (default: codex). "
            "To open different agents per pane (e.g. claude + opencode + codex), use agent_race_panes instead. "
            "By default panes are added to the caller/source workspace when available, otherwise the active workspace in the resolved window. "
            "Set newWorkspace=true to open them in a brand-new workspace instead. "
            "Pass prompt to send an initial message to each agent — Enter is pressed automatically so the agent starts immediately."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "repo": {"type": "string", "default": "."},
                "names": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "One name per worktree/pane to create.",
                },
                "base": {"type": "string", "default": "HEAD"},
                "worktreeRoot": {"type": "string"},
                "agent": {
                    "type": "string",
                    "default": "codex",
                    "description": (
                        "Legacy multi-pane agent selector. All 14 catalog IDs plus shell are supported; "
                        "custom agent names must also provide command. For an exact single-agent launch "
                        "with profiles/model/argv audit, prefer open_agent_pane."
                    ),
                },
                "command": {"type": "string"},
                "prompt": {
                    "type": "string",
                    "description": "Initial prompt sent to every agent after startup. For AI agents this is a Soyeht agent message with sender/reply metadata by default. Enter is pressed automatically.",
                },
                "promptMode": PROMPT_MODE_PROPERTY,
                "promptDelayMs": PROMPT_DELAY_MS_PROPERTY,
                "fromConversationID": FROM_CONVERSATION_ID_PROPERTY,
                "fromHandle": FROM_HANDLE_PROPERTY,
                "noCreate": {"type": "boolean", "default": False},
                "newWorkspace": {
                    "type": "boolean",
                    "default": False,
                    "description": "When true, open all panes in a brand-new workspace instead of the active one.",
                },
                "workspaceName": {
                    "type": "string",
                    "description": "Name for the new workspace when newWorkspace=true.",
                },
                "nameStyle": {"type": "string", "enum": NAME_STYLE_CHOICES},
                "paneNameStyle": {
                    "type": "string",
                    "enum": NAME_STYLE_CHOICES,
                    "description": "Pane/tab names default to short hyphen names, e.g. 'Fix Login Bug' becomes @fix-login.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_BATCH_CREATE_TIMEOUT},
            },
            "required": ["names"],
        },
    },
    {
        "name": "open_workspace",
        "description": (
            "Create a brand-new Soyeht workspace and open multiple panes inside it. "
            "Each pane uses an existing directory path — no git worktree creation is done here. "
            "Use this when you already have directories ready, or when the user asks to open a new workspace. "
            "To create git worktrees AND open them in a new workspace in one call, use agent_race_panes with newWorkspace=true instead. "
            "If prompt is provided for an AI agent, it is delivered as a Soyeht agent message with sender/reply metadata by default; set promptMode=raw only for literal terminal input."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "branch": {"type": "string"},
                "panes": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "name": {"type": "string"},
                            "path": {"type": "string"},
                            "agent": {"type": "string"},
                            "command": {"type": "string"},
                            "prompt": {"type": "string"},
                            "promptMode": PROMPT_MODE_PROPERTY,
                            "promptDelayMs": PROMPT_DELAY_MS_PROPERTY,
                        },
                        "required": ["name", "path"],
                    },
                },
                "agent": {"type": "string", "default": "shell"},
                "command": {"type": "string"},
                "prompt": {"type": "string"},
                "promptMode": PROMPT_MODE_PROPERTY,
                "promptDelayMs": PROMPT_DELAY_MS_PROPERTY,
                "fromConversationID": FROM_CONVERSATION_ID_PROPERTY,
                "fromHandle": FROM_HANDLE_PROPERTY,
                "nameStyle": {"type": "string", "enum": NAME_STYLE_CHOICES},
                "paneNameStyle": {
                    "type": "string",
                    "enum": NAME_STYLE_CHOICES,
                    "description": "Pane/tab names default to short hyphen names.",
                },
                "workspaceNameStyle": {
                    "type": "string",
                    "enum": NAME_STYLE_CHOICES,
                    "description": "Workspace names default to short space names, ideally one or two words. Use verbatim when the user asks for an exact name.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_BATCH_CREATE_TIMEOUT},
            },
            "required": ["panes"],
        },
    },
    {
        "name": "agent_race_panes",
        "description": (
            "Create one git worktree per AI agent and open each in its own Soyeht tab/pane. "
            "Default agents are codex, claude (Claude Code), and opencode — one worktree each. "
            "Use this whenever the user asks to start multiple AI agents side by side, "
            "'create 3 worktrees with different agents', or 'open claude + opencode + codex'. "
            "Pass prompt to send an initial message to every agent — Enter is pressed automatically so they start working immediately. "
            "By default panes are added to the caller/source workspace when available, otherwise the active workspace in the resolved window. "
            "Set newWorkspace=true to open all agent panes in a brand-new workspace instead."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "repo": {"type": "string", "default": "."},
                "agents": {
                    "type": "array",
                    "items": {"type": "string"},
                    "default": ["codex", "claude", "opencode"],
                    "description": "Catalog agent IDs to launch. Each gets its own worktree and tab; all 14 IDs in open_agent_pane are accepted.",
                },
                "prefix": {
                    "type": "string",
                    "default": "bug",
                    "description": "Branch/worktree name prefix. Each worktree is named <prefix>-<agent>.",
                },
                "base": {"type": "string", "default": "HEAD"},
                "worktreeRoot": {"type": "string"},
                "prompt": {
                    "type": "string",
                    "description": "Initial prompt sent to every agent after startup. For AI agents this is a Soyeht agent message with sender/reply metadata by default. Enter is pressed automatically so the agent starts executing immediately.",
                },
                "promptMode": PROMPT_MODE_PROPERTY,
                "promptDelayMs": PROMPT_DELAY_MS_PROPERTY,
                "fromConversationID": FROM_CONVERSATION_ID_PROPERTY,
                "fromHandle": FROM_HANDLE_PROPERTY,
                "noCreate": {"type": "boolean", "default": False},
                "newWorkspace": {
                    "type": "boolean",
                    "default": False,
                    "description": "When true, open the agent panes in a brand-new workspace instead of adding them to the active workspace.",
                },
                "workspaceName": {
                    "type": "string",
                    "description": "Name for the new workspace when newWorkspace=true. Defaults to a short generated name.",
                },
                "nameStyle": {"type": "string", "enum": NAME_STYLE_CHOICES},
                "paneNameStyle": {
                    "type": "string",
                    "enum": NAME_STYLE_CHOICES,
                    "description": "Pane/tab names default to short hyphen names.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_BATCH_CREATE_TIMEOUT},
            },
        },
    },
]
