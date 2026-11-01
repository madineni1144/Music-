# Madineni Music iOS 1.5.4

This folder is a native iOS Xcode project for the v1.5.4 interface. During the initial catalog download, it shows the first page quickly and publishes the full catalog after pagination completes, instead of redrawing the library after every page.

## Open and run

1. On your Mac, clone this repository, then open `ios/MadineniMusic.xcodeproj` in Xcode.
2. Select the **MadineniMusic** scheme and your iPhone as the run destination.
3. In **Signing & Capabilities**, choose your Apple development team. Keep the bundle identifier `xyz.madineni.music.performance` unless you want a different app identity.
4. Connect the iPhone, select **Run**, and trust the developer profile on the phone if iOS asks.

The project targets iOS 17 or later. Xcode will sign the app with the selected development team; the source package does not contain a pre-signed installable app.
