# Tandem

Tandem (formerly Automater) is a compact native macOS utility for repeating mouse clicks and keyboard presses, recording macros, and keeping clipboard history close at hand.

- **Repeat:** mouse clicks or keyboard shortcuts, adjustable intervals and repeat counts, current, fixed, or multiple points, and optional app targeting. Multiple points can run sequentially or as a fast burst. Re-pick individual points without rebuilding the list.
- **Macros:** record, edit, save, and replay mouse and keyboard sequences, with finite or continuous loops. Choose Foreground playback for keyboard/text macros or Background for mouse sequences. Recorded mouse points follow their original windows.
- **Clipboard:** search and preview recent text, image, and file copies. Choose how many copies to keep and when they expire in Clipboard Settings or Options → Auto-Cleanup. Pinned items stay; pin up to 30, copy them again, or paste into the previous app. Open history from the panel or with **Control–Option–V**; pause or clear it anytime.
- **Appearance:** Light, Dark, or System mode, six accent colors, an optional menu bar icon, and a panel that can stay on top.

The main window stays focused on Repeat and Macros. Clipboard history and Settings open separately. The menu bar icon can reopen the panel and control playback. **Control–Option–S** stops all automation, including a pending clipboard paste. Global shortcuts can be changed in Settings.

The paired-arrow mark represents repetition and a companion working beside you. The app keeps its existing bundle identifier and local storage when upgrading from Automater.

The native menus provide macro creation, import/export, duplication, clipboard search, appearance controls, and playback commands. Use **⌘1/⌘2** for Repeat/Macros, **⌘⇧V** for clipboard history, **⌘S** to save a macro, and **⌘.** to stop everything while Tandem is active. Unsaved macro changes are protected when switching macros or quitting.

## Background clicks

Turn **Background** on, choose **Fixed point**, then use **Pick…** to click the spot once. This also selects its app and window. Start the repeat and use your mouse in another window. The point follows the chosen window when it moves; closing or minimizing that window stops the repeat. Multiple points and explicit window selection are also available.

## Compatibility

Background delivery uses macOS accessibility actions and synthetic events. Apps may reject these inputs; Automater reports that as foreground recommended. It does not attempt to bypass app input protections.

## Testing

Run unit tests with `cd AutomaterMac && swift test`.

To produce a local review build, run `AutomaterMac/scripts/bundle_app.sh`, then `AutomaterMac/scripts/install_local.sh`. This installer closes the existing Automater instance before replacing it, so duplicate windows are not left running. Use `AutomaterMac/scripts/create_dmg.sh` to produce the DMG. Release signing and notarization require a Developer ID identity and a `notarytool` keychain profile; credentials are never stored in this repository.

See [the QA matrix](docs/QA.md), [privacy policy](docs/PRIVACY.md), and [support policy](docs/SUPPORT.md).

## License

This project is licensed under the [MIT License](LICENSE).
