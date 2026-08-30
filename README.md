# RtVS - Roblox to Visual Studio

![RtVS Logo](https://cdn.catman6112.dev/Images/RtVS.png)

(works with any code editor btw, not just visual studio code)

**Version: 0.1.7**

A bidirectional synchronization system that connects Roblox Studio to your file system, enabling version control and external editing of Roblox game content.

## Installation

The easiest way to install RtVS. Handles Node.js setup, plugin deployment, and optional desktop shortcuts automatically.

**Linux / macOS** - open a Terminal and run:
```bash
sh -c "$(curl -sS https://raw.githubusercontent.com/R12sa/RtVS_Roblox-To-Visual-Studio/main/install.sh)"
```

**Windows** - open PowerShell and run:
```powershell
irm https://raw.githubusercontent.com/R12sa/RtVS_Roblox-To-Visual-Studio/main/install.ps1 | iex
```

> On Windows, press `Win + R`, type `powershell`, and hit Enter to open PowerShell.

The installer checks for Node.js 18+, downloads RtVS, installs dependencies, deploys the plugin, and optionally creates shortcuts.

See [QUICKSTART.md](QUICKSTART.md) for manual installation.

## Features

- Bidirectional sync between Roblox Studio and file system
- Edit scripts in external editors
- Real-time file watching and automatic updates
- Priority modes to control sync direction
- Complete Roblox datatype serialization
- Git-friendly file structure
- Version compatibility checking

## Quick Start

See QUICKSTART.md for installation and setup instructions.

## Known Issues

- Script duplication can occur if files are renamed or moved during active sync.

## Architecture

The system consists of two main components:

**Server (Node.js/TypeScript):**
- HTTP server running on localhost:8080
- File system watcher using chokidar
- Serialization/deserialization of Roblox datatypes
- REST API for plugin communication

**Plugin (Roblox Studio):**
- Toolbar UI with sync controls
- Instance tree serialization
- Bidirectional sync with priority modes
- Automatic version compatibility checking

**Output:**
- `/synced-game` directory containing the synchronized file structure
- Scripts as `.lua`, `.local.lua`/`.client.lua`, or `.module.lua`
- Properties as `__main__.json` files
- Complete hierarchy in `index.json`

## How It Works

1. Install RtVS using the installer
2. Start the server with `npm start`
3. Use priority mode:
   - Bidirectional Sync
        Checks for changes on both sides continuously, allows editing on studio to be synced to scripts while changes on the file system are synced to the script.
> Prioritize Studio, Prioritize Server, and Full Sync have all been depreciated to Bidirectional Sync which is relaible and reccomended for working with collaborators or just any usage in general.
> In addition, Smart Sync has been removed as it just like... didn't function at all ...

See `plugin/README.md` for detailed usage.

## Project Files

- `QUICKSTART.md` - Installation and setup guide
- `plugin/README.md` - Plugin usage, workflows, and file format documentation
- `server/` - Node.js/TypeScript server source code
- `plugin/` - Roblox Studio plugin Lua source code

## Requirements

- Node.js 18+
   > automatically installed by install script
- Roblox Studio
- Windows, macOS, or Linux

## License

Attribution-NonCommercial-NoDerivatives 4.0 International (see LICENSE.md)

## Contributing

This project is in active development. Pull requests are welcome.


