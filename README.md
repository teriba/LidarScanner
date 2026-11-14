# LiDAR Scanner

SwiftUI iOS app (iOS 17+) that scans with the LiDAR sensor or the front TrueDepth camera and saves 3D models.

| Mode | Framework | Output |
|---|---|---|
| Object | `ObjectCaptureSession` + on-device `PhotogrammetrySession` | Textured USDZ |
| Room | RoomPlan | Parametric USDZ (walls, doors, windows, furniture as boxes), one flat colour per part taken from the camera |
| Raw mesh | ARKit scene reconstruction | Untextured OBJ in world space, faces grouped by ARKit class (wall, floor, ...) |
| Face | ARKit face tracking (front TrueDepth camera) | Textured USDZ of the face mesh at real size, texture projected from one camera image |

Scans are stored in `Documents/Scans/<Kind>/` and show up in the Files app under "On My iPhone > LiDAR Scanner". The app has a 3D viewer, AR Quick Look for USDZ, and a share sheet.

## Raw mesh conversions

Open a raw mesh in the viewer and tap the wand. Each action runs in the background and saves a new OBJ. The original is never changed.

| Action | Result | Saved under |
|---|---|---|
| Clean up | One welded mesh: duplicate vertices merged (1 cm), bad triangles and small loose pieces removed, decimated to 35 % (at most 250k triangles), new normals | Raw meshes |
| Convert to room | Flat floor, ceiling and wall quads from detected planes, furniture as boxes | Rooms |
| Convert to object | The piece nearest the middle of the scan, with the floor or table it stands on and the walls removed, small holes filled, moved to the origin | Objects |

Room and object conversion use the ARKit face classes when the file has them. Older OBJ files without classes work too, from geometry alone.

The code is in `LidarScanner/Mesh/`: `MeshProcessing` (weld, components, decimation, hole filling), `MeshPlanes` (floor levels and wall planes), `MeshRoomBuilder`, `MeshObjectIsolator`, `OBJFile` and `MeshConversion` (the three pipelines). These files only need Foundation and simd, so they also compile on macOS for testing.

## Run on a phone

1. Open `LidarScanner.xcodeproj` in Xcode 16 or later.
2. Target > Signing & Capabilities: pick your team. Change the bundle ID if it is taken.
3. Run on a LiDAR device (iPhone 12 Pro or later Pro model, or iPad Pro). Face scans only need a TrueDepth camera. The simulator has no camera, so scanning does not work there.

## Tips

- Object: matte, textured objects work best. Avoid shiny, transparent or very thin things. Do a second pass after flipping the object to capture its underside.
- Room: move slowly and point at the floor-wall edges. Tap Done when the outline is complete. Colours come from the camera, so look at every wall and piece of furniture in good light. Parts the camera never saw stay grey.
- Raw mesh: works for anything, including outdoors, but has no colours.
- Face: needs a device with Face ID. Even light from the front, look straight at the camera and hold still for half a second after tapping Capture. The texture comes from a single front view, so the sides of the face are stretched.
- Convert to room: scan the floor and the full height of every wall. If the walls do not close into a loop, the floor is built from the scanned floor area instead.
- Convert to object: walk around the object so it ends up in the middle of the scan.
