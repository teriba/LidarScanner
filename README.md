# LiDAR Scanner

SwiftUI iOS app (iOS 17+) that scans with the LiDAR sensor and saves 3D models.

| Mode | Framework | Output |
|---|---|---|
| Object | `ObjectCaptureSession` + on-device `PhotogrammetrySession` | Textured USDZ |
| Room | RoomPlan | Parametric USDZ (walls, doors, windows, furniture as boxes), one flat colour per part taken from the camera |
| Raw mesh | ARKit scene reconstruction | Untextured OBJ in world space |

Scans are stored in `Documents/Scans/<Kind>/` and show up in the Files app under "On My iPhone > LiDAR Scanner". The app has a 3D viewer, AR Quick Look for USDZ, and a share sheet.

## Run on a phone

1. Open `LidarScanner.xcodeproj` in Xcode 16 or later.
2. Target > Signing & Capabilities: pick your team. Change the bundle ID if it is taken.
3. Run on a LiDAR device (iPhone 12 Pro or later Pro model, or iPad Pro). The simulator has no camera, so scanning does not work there.

## Tips

- Object: matte, textured objects work best. Avoid shiny, transparent or very thin things. Do a second pass after flipping the object to capture its underside.
- Room: move slowly and point at the floor-wall edges. Tap Done when the outline is complete. Colours come from the camera, so look at every wall and piece of furniture in good light. Parts the camera never saw stay grey.
- Raw mesh: works for anything, including outdoors, but has no colours.
