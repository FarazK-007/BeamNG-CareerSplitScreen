# BeamNG.drive Career Mode Split-Screen Co-op Mod + RLS Career Overhaul support 🚗💨

[![BeamNG Version](https://img.shields.io/badge/BeamNG.drive-v0.33%2B-orange.svg)](https://beamng.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows-lightgrey.svg)]()
[![Status](https://img.shields.io/badge/Status-Stable%20%2F%20Ready-brightgreen.svg)]()

Enables native, local split-screen multiplayer inside **BeamNG.drive Career Mode**. Play co-op with a friend using owned fleet vehicles from your garage or guest loaners, with independent cameras, separate controllers, individual minimaps, isolated GPS navigation, and fully synchronized parcel delivery missions!

---

## ✨ Features

### 📦 Independent Co-op Parcel Delivery & Logistics
- **Full Cargo Delivery Support**: Player 2 can pick up parcels, cargo, and freight at any logistics facility and deliver them to their destination independently.
- **Independent Drop-Offs**: Player 2 can confirm deliveries at parking spots without requiring Player 1 to be nearby.
- **Accurate Driver Attribution**: Precision parking rewards and delivery payouts are credited accurately based on the vehicle that actually transported and parked the cargo (Player 1 or Player 2).
- **Traffic Car Isolation**: Delivery querying exclusively scans player vehicles and inventory, preventing AI or traffic cars from stalling or hanging delivery completion.

### 🎨 Character & Route Decal Color Matching
- **Color-Coded Players**:
  - **Player 1**: Orange character icon / minimap blip with matching **Orange** 3D navigation road ribbon.
  - **Player 2**: Blue character icon / minimap blip with matching **Blue** 3D navigation road ribbon.
- **Always Visible Route Decals**: Extended fade distance ensures Player 2's route decals never disappear or hide when Player 1 drives far away.
- **Gated to Split-Screen**: In single-player mode, native default route colors remain completely unchanged.

### 💰 On-Screen Career Balance & UI Refresh HUD
- **Live Cash Balance**: Sleek, modern top-left HUD pill in split-screen showing current Career money alongside the official BeamNG currency icon.
- **Instant Refresh Button**: Compact square button with vector refresh icon to reload split-screen minimaps, UI overlays, and vehicle blips with a single click.

### 🚗 Career Fleet Co-op & Persistence
- **Drive Owned Fleet Vehicles**: Player 2 can drive any secondary vehicle owned in your Career garage.
- **Full State Persistence**: Fuel consumption, mileage, wear, and mechanical damage incurred by Player 2 are seamlessly saved directly back into your Career profile inventory.
- **Auto-Spawn Loaner / Buddy Car**: If you only own a single vehicle in your save, the mod automatically spawns a guest loaner vehicle (Ibishu Covet) next to you so you can jump into co-op immediately.
- **Passenger Ride-Along**: Player 2 can also spawn as a passenger in Player 1's car. Press **F** to step out, walk around, or hop into another car.

### 🎮 Intelligent Device Management & Input Protection
- **Multiple Device Pre-Flight Check**: Automatically verifies that multiple controllable devices (e.g. Keyboard + Gamepad, Steering Wheel, or dual gamepads) are connected before launching split-screen. If only a single device is detected, co-op start is safely aborted with an informative notification so single-player controls are never disrupted.
- **Smart Default Device Assignment**: Defaults **Keyboard & Mouse to Player 1** and assigns the **next connected device (controller/wheel) to Player 2**.
- **Zero Input Lockout / Disconnection Guard**: Single-player controls (ESC pause menu, M map, driving keys) are 100% protected and remain fully operational across game boots and restarts. Devices are never left in an unassigned or disconnected state.
- **Button (A) / Key Interaction**: Interactive world markers (drop-off parking spots, fuel pumps, garage doors, mission triggers) display on the screen of whichever player is in proximity.
- **Controller Action Routing**: Controller button `(A)` and keyboard `[E]` work reliably for both players, with intelligent fallback routing to ensure Player 2 prompts are never dropped.
- **Steering Isolation**: Steering inputs are isolated so Player 2 can freely turn and drive even when Player 1 is inside an interaction area.

### 🗺️ Dual Minimaps & Independent GPS Navigation
- **Individual Minimaps**: Each player gets a dedicated on-screen minimap centered on their own vehicle with independent zoom and directional orientation.
- **Dual GPS Routing**:
  - Player 1 has their own navigation route (Orange).
  - Player 2 has their own independent navigation route (Blue).
  - Setting a waypoint for one player does **not** overwrite or interfere with the other player's navigation.
- **Screen-Isolated 3D Road Decals**: In-world road navigation ribbons display clearly without cross-screen bleeding.

### 🎯 Enhanced Big Map (Split-Screen Gated)
- **Individual Route Planning**: Top bar switcher (`Route For: Player 1 | Player 2`) allows selecting which player receives newly placed map waypoints.
- **Center Crosshair Pin**: Always-visible center crosshair pin in split-screen mode for rapid, intuitive destination selection.
- **Quick Waypoint Marking**: Press **Enter**, **Space**, or **Controller (A)** to instantly drop or clear a route at the crosshair pin.
- **Drag-Free Mouse Waypoints**: Left-clicking anywhere on the map places a route waypoint directly without panning or dragging the camera.
- **100% Native in Single-Player**: All Big Map customizations are strictly gated to split-screen sessions—single-player freeroam and career map navigation remain completely untouched.

### ⚙️ Seamless Radial & Pause Menu Controls
- **Radial Menu (E / Gamepad D-pad)**:
  - Clean bottom-slot entry (**6 o'clock**) to start or manage split-screen.
  - Automatically dismisses instantly upon selection without UI stutter or delay.
  - Quick sub-menu options for Settings, Teleport P2, Car Swap, and Exit.
- **Pause Menu (ESC)**:
  - Integrated home-rail actions: **Toggle Layout (Horizontal / Vertical)**, **Teleport P2 to P1**, **Get / Switch P2 Car**, **Split-Screen Settings**, and **Exit Split-Screen**.
  - Uses native BeamNG UI icon glyphs (`splitScreen`, `fastTravel`, `carsChange`, `cogs`, `abandon`).

### 🛡️ Structured Mission Protection
- When Player 1 enters a timed Career mission, scenario, or challenge, the mod automatically switches to a full-screen solo camera view to guarantee checkpoint and timer stability.
- Once the mission concludes or is abandoned, split-screen is smoothly restored.

### 🧩 Full Compatibility (Vanilla + RLS Career Overhaul)
- **Vanilla Career Mode**: 100% native out-of-the-box support.
- **RLS Career Overhaul**: Fully supported! Automatically recognizes RLS's custom game state (`overhaul`), the RLS garage inventory (`overhaul_career_garage_inventory`), RLS progression, and custom overhaul maps (West Coast, Utah, Italy, Hirochi Raceway, etc.).
- **Multi-Level Reputation Fix**: Patches career reputation calculations to eliminate crashes with organizations that have more than 5 levels (e.g. Utah in RLS).
- **Zero File Conflicts**: Clean, non-destructive bridging that coordinates directly with BeamNG and RLS internal multiseat hooks.

---

## 🚀 Installation

### Option 1: Quick Install (PowerShell)
1. Clone or download this repository.
2. Open PowerShell in the mod directory and run:
   ```powershell
   .\install_career_splitscreen.ps1
   ```
3. The script automatically packages `CareerSplitScreen.zip` and deploys it directly into your active BeamNG mods directory:
   `%LocalAppData%\BeamNG\BeamNG.drive\current\mods\`

### Option 2: Manual Install (.zip)
1. Download the pre-built `CareerSplitScreen.zip` from the latest GitHub Release.
2. Move `CareerSplitScreen.zip` into your BeamNG mods folder:
   ```
   C:\Users\<YourUsername>\AppData\Local\BeamNG\BeamNG.drive\current\mods\
   ```
3. Launch BeamNG.drive.

---

## 📖 How to Play

1. Start **BeamNG.drive** and load your **Career Mode** save.
2. Enter your vehicle.
3. Open the **Radial Menu (E / D-Pad Down)** or **Pause Menu (ESC)**.
4. Select **Start Split-Screen**.
5. Once Player 2 spawns:
   - Go to **Pause Menu -> Split-Screen Settings** to verify controller assignments and screen layout (horizontal vs. vertical split).
6. Press **M** anytime to open the Big Map, select **Route For: P1** or **P2**, and navigate West Coast USA together!
7. Pick up parcel deliveries at logistics facilities with Player 1 or Player 2 and drive to drop-off parking spots to earn cash and reputation!
8. Need to regroup? Use **Teleport P2 to P1** from the Pause or Radial menu to bring Player 2 right next to Player 1 fully repaired.

---

## 🕹️ Controls & Keybindings (DEFAULT)

| Action | Keyboard | Controller | Description |
| :--- | :--- | :--- | :--- |
| **Radial Menu** | `E` | `D-Pad Down` | Open radial action wheel |
| **Pause Menu** | `ESC` | `Start / Options` | Open pause menu with split-screen rail |
| **Big Map** | `M` | `Select / View` | Open world map with dual player route selector |
| **Set Route at Pin** | `Enter` / `Space` | `(A)` | Drop or remove navigation waypoint at map pin |
| **Interact / Drop-Off** | `E` | `(A)` / Configured | Trigger delivery drop-off, gas pump, or garage prompt |
| **Get In / Out** | `F` | `(Y)` / Configured | Exit vehicle to walk or enter another vehicle |

---

## 📁 Repository Structure

```
CareerSplitScreen/
├── lua/
│   └── ge/
│       └── extensions/
│           ├── careerSplitScreen.lua               # Core coordinator, UI HUD, & hooks
│           ├── career/modules/
│           │   ├── inventory.lua                  # Fleet vehicle persistence
│           │   ├── reputation.lua                 # Multi-level reputation crash fix
│           │   └── delivery/                      # Co-op parcel & logistics system
│           │       ├── general.lua                # Container querying & drop-off prompts
│           │       ├── parcelManager.lua          # Driver attribution & label routing
│           │       ├── precisionParking.lua       # Driver precision parking score
│           │       ├── progress.lua               # Independent drop-off confirmation
│           │       └── tutorial.lua               # Co-op delivery tutorial checks
│           ├── core/
│           │   ├── groundMarkers.lua              # P1 Orange & P2 Blue road ribbons
│           │   ├── multiseat.lua                  # Multiseat initialization
│           │   ├── quickAccess.lua                # Radial menu integration
│           │   └── input/actions/
│           │       └── careerSplitScreen.json     # Custom action definitions
│           ├── gameplay/
│           │   ├── markerInteraction.lua          # Per-player interaction prompts & bounds
│           │   └── rawPois.lua                    # POI resolution
│           ├── render/
│           │   └── splitScreen.lua                # Split-screen viewport rendering
│           └── ui/
│               ├── apps/minimap/
│               │   ├── minimap.lua                # Dual independent minimaps
│               │   ├── route.lua                  # Per-player route rendering
│               │   └── vehicles.lua               # Minimap blips & icons
│               ├── multiseat/
│               │   ├── freeroam.lua               # Multiseat freeroam controller
│               │   └── multiseatVehicles.lua      # Player seat assignments
│               └── pause/features/
│                   └── homeRail.lua               # ESC pause menu buttons & icons
├── scripts/
│   └── careerSplitScreen/
│       └── modScript.lua                          # Auto-load bootstrap script
├── install_career_splitscreen.ps1                 # Build & deployment script
├── CareerSplitScreen.zip                          # Packaged release mod
├── mod_info.json                                  # BeamNG mod metadata
├── LICENSE                                        # MIT License
└── README.md                                      # Documentation
```

---

## 🤝 Contributing

Contributions, bug reports, and feature suggestions are welcome! Feel free to open an Issue or submit a Pull Request.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).  
BeamNG.drive is a registered trademark of BeamNG GmbH. This mod is an independent community project.
